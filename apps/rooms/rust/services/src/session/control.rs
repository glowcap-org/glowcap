//! Filesystem-authorized local view of a Rooms session. The executable composes
//! this adapter with the peer; neither the application nor session notices
//! depend on it. A failed observer leaves commands and other views available.
mod failure;
mod feed;
mod inbox;
mod worker;
pub use failure::Failure;
use feed::{Application, Feed};
use rooms_application::{grants::Access, session::command::Request};
use rooms_runtime::service::LocalObservation;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{cell::RefCell, path::PathBuf, rc::Rc, time::Duration};
use tokio::{
	io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
	net::{UnixListener, UnixStream},
	sync::Notify,
};

pub type Report = Rc<dyn Fn(Failure)>;
pub struct Control {
	listener: UnixListener,
	path: PathBuf,
	feed: Rc<Feed>,
	observation: RefCell<Option<LocalObservation>>,
	storage: worker::Owner,
	report: Report,
	stop: Notify,
}
#[derive(Deserialize)]
#[serde(tag = "verb", rename_all = "kebab-case", deny_unknown_fields)]
enum RequestBody {
	Status,
	Locate {
		locator: String,
	},
	Tick {
		#[serde(default)]
		wait: u64,
		#[serde(default)]
		after: Option<u64>,
	},
	Ack {
		ids: Vec<u64>,
	},
	Command {
		id: String,
		name: String,
		args: Vec<String>,
	},
	Adopt,
	Resume,
	Stop,
}
fn snapshot(app: &Application) -> Result<Value, Failure> {
	let s = app.snapshot()?;
	let workspace: Value = serde_json::from_str(&s.checkpoint.encode_for(Access::Interact).map_err(Failure::invalid)?)?;
	Ok(json!({"ok": true, "revision": s.revision.get(), "workspace": workspace,
        "rooms": s.room_views, "directories": s.directory_views, "connected": s.connected_directories,
        "issues": s.issues, "pending_effects": s.pending_effect_details, "adoption": s.workspace_adoption}))
}
impl Control {
	pub async fn open(peer: &super::Peer, report: Report) -> Result<Self, Failure> {
		use std::os::unix::fs::FileTypeExt;
		let app = peer
			.local()
			.map_err(|error| Failure::new("closed", "after-state-change", error))?;
		let state = &peer.state_directory;
		// Acquire this adapter's exclusive custody before touching its socket.
		let storage = worker::Owner::open(state.join("inbox")).await?;
		let path = state.join("control.sock");
		let prepared = async {
			match tokio::fs::symlink_metadata(&path).await {
				Ok(metadata) if metadata.file_type().is_socket() => tokio::fs::remove_file(&path).await?,
				Ok(_) => return Err(Failure::invalid("control.sock exists and is not a socket")),
				Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
				Err(e) => return Err(e.into()),
			}
			Ok::<_, Failure>(())
		}
		.await;
		if let Err(error) = prepared {
			if let Err(cleanup) = storage.close().await {
				report(cleanup);
			}
			return Err(error);
		}
		let listener = match UnixListener::bind(&path) {
			Ok(listener) => listener,
			Err(error) => {
				storage.close().await?;
				return Err(error.into());
			}
		};
		let feed = Rc::new(Feed {
			app: app.clone(),
			inbox: storage.worker.clone(),
			failure: RefCell::new(None),
		});
		let observation = match app.observe(feed.clone()) {
			Ok(observation) => observation,
			Err(error) => {
				let closed = storage.close().await;
				if closed.is_ok()
					&& let Err(cleanup) = tokio::fs::remove_file(&path).await
				{
					report(cleanup.into());
				}
				if let Err(cleanup) = closed {
					report(cleanup);
				}
				return Err(error.into());
			}
		};
		Ok(Self {
			listener,
			path,
			feed,
			observation: RefCell::new(Some(observation)),
			storage,
			report,
			stop: Notify::new(),
		})
	}
	async fn pending(&self) -> Result<Value, Failure> {
		let failure = self.feed.failure.borrow_mut().take();
		if let Some(error) = failure {
			self.feed.inbox.gap(error).await?;
		}
		let result = self.feed.inbox.pending().await?;
		if !result["gap"].is_null() {
			self.observation.borrow_mut().take();
		}
		Ok(result)
	}
	async fn execute(&self, request: RequestBody) -> Result<Value, Failure> {
		let app = &self.feed.app;
		match request {
			RequestBody::Adopt => {
				let s = app.snapshot()?;
				if s.workspace_adoption == rooms_application::session::snapshot::views::Adoption::Available {
					let id = rooms_application::session::state::OperationId::new("local-adopt".into())
						.ok_or_else(|| Failure::invalid("invalid adoption id"))?;
					app.adopt(
						id,
						s.revision.get(),
						rooms_application::session::checkpoint::Checkpoint::empty(),
					)?
					.wait()
					.await?;
				}
				Ok(json!({"ok": true}))
			}
			RequestBody::Status => {
				let mut result = snapshot(app)?;
				let inbox = self.pending().await?;
				result["inbox"] = json!({"remaining": inbox["remaining"], "gap": inbox["gap"]});
				Ok(result)
			}
			RequestBody::Locate { locator } => {
				let address = rooms_glowcap::routes::Address::directory(&locator)
					.map_err(Failure::invalid)?
					.ok_or_else(|| Failure::invalid("invalid directory locator"))?;
				Ok(
					json!({"ok": true, "id": address.authority, "locator": address.address, "transport": address.transport}),
				)
			}
			RequestBody::Tick { wait, after } => {
				if wait > 30 {
					return Err(Failure::invalid("wait must be 0..30 seconds"));
				}
				let deadline = tokio::time::Instant::now() + Duration::from_secs(wait);
				let mut updates = self.feed.inbox.updates();
				loop {
					let pending = self.pending().await?;
					let changed = after.map_or(pending["remaining"] != 0, |cursor| {
						pending["cursor"].as_u64() != Some(cursor)
					});
					if changed || !pending["gap"].is_null() || tokio::time::Instant::now() >= deadline {
						return Ok(pending);
					}
					tokio::select! {
						result = updates.changed() => result.map_err(Failure::uncertain)?,
						_ = tokio::time::sleep_until(deadline) => {},
					}
				}
			}
			RequestBody::Ack { ids } => self.feed.inbox.ack(ids).await,
			RequestBody::Resume => {
				self.pending().await?;
				self.feed.inbox.resume().await?;
				if self.observation.borrow().is_none() {
					*self.observation.borrow_mut() = Some(app.observe(self.feed.clone())?);
				}
				Ok(
					json!({"ok": true, "observing": true, "notice": "past observation gap accepted; listening to new events"}),
				)
			}
			RequestBody::Stop => Ok(json!({"ok": true})),
			RequestBody::Command { id, name, args } => {
				let s = app.snapshot()?;
				let args: Vec<_> = args.into_iter().map(glowcap::Argument::String).collect();
				let args: Vec<_> = args.iter().map(rooms_glowcap::Value).collect();
				let request = Request::new(Access::Admin, &id, s.revision.get(), &name, &args)
					.map_err(rooms_runtime::Error::command)?;
				let revision = app.command(&request)?.wait().await?;
				Ok(json!({"ok": true, "operation": id, "revision": revision}))
			}
		}
	}
	async fn connection(&self, stream: UnixStream) -> Result<(), Failure> {
		let (read, mut write) = stream.into_split();
		let mut read = BufReader::new(read);
		let mut bytes = Vec::new();
		loop {
			let available = read.fill_buf().await?;
			if available.is_empty() {
				if bytes.is_empty() {
					return Ok(());
				} // A connect-only readiness probe.
				return Err(Failure::invalid("incomplete control request"));
			}
			let end = available.iter().position(|b| *b == b'\n');
			let count = end.map_or(available.len(), |i| i + 1);
			if bytes.len() + count > 1024 * 1024 {
				return Err(Failure::exhausted("control request exceeds 1 MiB"));
			}
			bytes.extend_from_slice(&available[..count]);
			read.consume(count);
			if end.is_some() {
				break;
			}
		}
		let mut stop = false;
		let result = match serde_json::from_slice(&bytes) {
			Ok(request) => {
				stop = matches!(request, RequestBody::Stop);
				self.execute(request).await
			}
			Err(error) => Err(error.into()),
		};
		let response = result.unwrap_or_else(|error| error.response());
		let mut bytes = serde_json::to_vec(&response)?;
		bytes.push(b'\n');
		write.write_all(&bytes).await?;
		if stop {
			self.stop.notify_one();
		}
		Ok(())
	}
	pub async fn serve(&self, halt: impl std::future::Future<Output = ()>) {
		use futures_util::{StreamExt, stream::FuturesUnordered};
		let mut clients = FuturesUnordered::new();
		let mut accepting = true;
		tokio::pin!(halt);
		loop {
			tokio::select! {
				_ = &mut halt => break,
				_ = self.stop.notified() => break,
				accepted = self.listener.accept(), if accepting && clients.len() < 8 => match accepted {
					Ok((stream, _)) => clients.push(tokio::time::timeout(Duration::from_secs(35), self.connection(stream))),
					Err(error) => {
						(self.report)(error.into());
						// Only the socket is unavailable; the peer still serves
						// its rooms and attached views until external shutdown.
						accepting = false;
					}
				},
				Some(result) = clients.next(), if !clients.is_empty() => match result {
					Ok(Ok(())) => {},
					Ok(Err(error)) => (self.report)(error),
					Err(error) => (self.report)(Failure::uncertain(error)),
				},
			}
		}
		self.detach();
	}
	fn detach(&self) {
		self.observation.borrow_mut().take();
	}
	pub async fn close(self) -> Result<(), Failure> {
		self.detach();
		let failed = self.feed.failure.borrow_mut().take();
		let gap = match failed {
			Some(error) => self.feed.inbox.gap(error).await,
			None => Ok(()),
		};
		// The retired journal still owns its directory lease. Hold it through
		// unlink so an old close cannot delete a replacement listener's socket.
		let storage = self.storage.close().await;
		let socket = if storage.is_ok() {
			tokio::fs::remove_file(&self.path).await.map_err(Failure::from)
		} else {
			Ok(())
		};
		let storage = storage.map(drop);
		let mut failures = Vec::new();
		for result in [gap, storage, socket] {
			if let Err(error) = result {
				(self.report)(error.clone());
				failures.push(error.to_string());
			}
		}
		if failures.is_empty() {
			Ok(())
		} else {
			Err(Failure::uncertain(failures.join("; ")))
		}
	}
}

#[cfg(test)]
mod tests;
