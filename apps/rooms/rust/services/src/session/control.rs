//! Filesystem-authorized local view of a Rooms session. The executable composes
//! this adapter with the peer. Neither the application nor session notices
//! depend on it. A failed observer leaves commands and other views available.
mod acquisitions;
mod commands;
mod failure;
mod feed;
mod inbox;
mod request;
mod worker;
pub use failure::Failure;
use feed::{Application, Feed};
use serde_json::{Value, json};
use std::{cell::RefCell, path::PathBuf, rc::Rc, time::Duration};
use tokio::{
	io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
	net::{UnixListener, UnixStream},
	sync::{Notify, watch},
};

pub type Report = Rc<dyn Fn(Failure)>;
pub struct Control {
	listener: UnixListener,
	path: PathBuf,
	feed: Rc<Feed>,
	observation: RefCell<Option<Observer>>,
	storage: Option<worker::Owner>,
	report: Report,
	stop: Notify,
	commands: commands::Commands,
	acquisitions: acquisitions::Acquisitions,
}
// Only acquisition requests allocate a candidate box. Keeping the workspace
// candidate out of the enum avoids retaining its size in every socket request;
// execute moves it into bounded acquisition admission and releases the box.
// Tick's `after` watches journal changes; `after_id` pages retained events.
request::request! {
	enum RequestBody, verb = "verb" {
		Status => "status" {},
		Locate => "locate" { locator: String },
		Tick => "tick" { #[serde(default)] wait: u64, #[serde(default)] after: Option<u64>, #[serde(default)] after_id: u64 },
		Ack => "ack" { ids: Vec<u64> },
		Command => "command" { id: String, base: u64, name: String, args: Vec<String> },
		ReleaseCommand => "release-command" { id: String },
		Acquire => "acquire" { id: String, request: Box<acquisitions::Request> },
		ReleaseAcquisition => "release-acquisition" { id: String },
		CommandResult => "command-result" { id: String, base: u64, name: String, args: Vec<String> },
		DirectoryRead => "directory-read" { id: String, peer: Option<String> },
		Resume => "resume" {},
		Stop => "stop" {},
	}
}
async fn snapshot(app: &Application) -> Result<Value, Failure> {
	let s = app.workspace.snapshot().await.map_err(peer_failure)?;
	Ok(json!({"ok": true, "revision": s.revision.to_string(), "workspace": s.intent}))
}
fn peer_failure(error: rooms_glowcap::client::Error) -> Failure {
	if let Some(failure) = error.admission_refusal() {
		return Failure::new(failure.code.wire(), failure.code.definition().retry.wire(), &error);
	}
	if let rooms_glowcap::client::Error::RefusedObservation(reason) = &error {
		if let Some(failure) = rooms_application::failure::Failure::parse(reason) {
			return Failure::new(failure.code.wire(), failure.code.definition().retry.wire(), reason);
		}
		return Failure::new("refused", "after-state-change", reason);
	}
	if let rooms_glowcap::client::Error::Observation(reason) = &error {
		return Failure::uncertain(reason);
	}
	rooms_runtime::Error::peer(error).into()
}
struct Observer {
	stop: watch::Sender<bool>,
	task: tokio::task::JoinHandle<()>,
}
fn observe(feed: Rc<Feed>) -> Observer {
	let (stop, mut stopping) = watch::channel(false);
	let task = tokio::task::spawn_local(async move {
		loop {
			let delivery = tokio::select! {
				biased;
				_ = stopping.changed() => return,
				result = feed.app.activity.receive_after(&feed.app.host, rooms_platform::HostPlatform, feed.cursor.get(), true) => result,
			};
			let failure = match delivery {
				Ok(delivery) if delivery.gap => {
					feed.cursor.set(delivery.cursor);
					Failure::uncertain("session activity backlog has a gap")
				}
				Ok(delivery) => {
					if delivery.unavailable
						&& let Err(error) = feed.inbox.event(json!({"unavailable":true})).await
					{
						*feed.failure.borrow_mut() = Some(error);
						feed.inbox.wake();
						return;
					}
					if let Some(event) = delivery.event
						&& let Err(failure) = feed.receive(delivery.cursor, event).await
					{
						*feed.failure.borrow_mut() = Some(failure);
						feed.inbox.wake();
						return;
					}
					feed.cursor.set(delivery.cursor);
					continue;
				}
				Err(error) => Failure::uncertain(error),
			};
			*feed.failure.borrow_mut() = Some(failure);
			feed.inbox.wake();
			return;
		}
	});
	Observer { stop, task }
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
		let feed = Rc::new(Feed::new(app, storage.worker.clone()));
		let observation = observe(feed.clone());
		Ok(Self {
			listener,
			path,
			feed,
			observation: RefCell::new(Some(observation)),
			storage: Some(storage),
			report,
			stop: Notify::new(),
			commands: commands::Commands::default(),
			acquisitions: acquisitions::Acquisitions::default(),
		})
	}
	async fn pending(&self, after_id: u64) -> Result<Value, Failure> {
		let failure = self.feed.failure.borrow_mut().take();
		if let Some(error) = failure {
			self.feed.inbox.gap(error).await?;
		}
		let result = self.feed.inbox.pending(after_id).await?;
		if !result["gap"].is_null() {
			self.detach().await;
		}
		Ok(result)
	}
	async fn execute(&self, request: RequestBody) -> Result<Value, Failure> {
		let app = &self.feed.app;
		match request {
			RequestBody::Acquire { id, request } => {
				self.acquisitions.submit(app, &id, *request).await?;
				Ok(json!({"ok":true,"acquisition":id}))
			}
			RequestBody::ReleaseAcquisition { id } => {
				self.acquisitions.release(&id).await?;
				Ok(json!({"ok":true}))
			}
			RequestBody::CommandResult { id, base, name, args } => {
				let command = app
					.workspace
					.prepare_command(&id, base, &name, &args)
					.await
					.map_err(peer_failure)?;
				let result = command.result().await.map_err(peer_failure)?;
				let data = result
					.as_str()
					.or_else(|| {
						result
							.as_list()
							.and_then(|values| values.first())
							.and_then(glowcap::Argument::as_str)
					})
					.ok_or_else(|| Failure::invalid("command has no committed data"))?;
				Ok(json!({"ok":true,"result":serde_json::from_str::<Value>(data)?,
					"adopted":command.adopted().await.map_err(peer_failure)?}))
			}
			RequestBody::DirectoryRead { id, peer } => {
				let reader = app.workspace.directory_reader(&id).await.map_err(peer_failure)?;
				let registration = match peer {
					Some(peer) => Some(
						reader
							.member_registration(&peer)
							.await
							.map_err(peer_failure)?
							.as_str()
							.to_owned(),
					),
					None => None,
				};
				Ok(
					json!({"ok":true,"location":reader.advertised_location().await.map_err(peer_failure)?,
					"rooms":reader.list().await.map_err(peer_failure)?,"registration":registration}),
				)
			}
			RequestBody::ReleaseCommand { id } => {
				self.commands.release(&id).await?;
				Ok(json!({"ok": true}))
			}
			RequestBody::Status {} => {
				let mut result = snapshot(app).await?;
				let inbox = self.pending(0).await?;
				result["inbox"] = json!({"remaining": inbox["remaining"], "gap": inbox["gap"]});
				Ok(result)
			}
			RequestBody::Locate { locator } => {
				let address = rooms_glowcap::routes::Address::directory(&locator)
					.map_err(Failure::invalid)?
					.ok_or_else(|| Failure::invalid("invalid directory locator"))?;
				let route = rooms_glowcap::routes::locator(&address.address)
					.ok_or_else(|| Failure::invalid("invalid directory route"))?;
				let uri = glowcap::format_sturdyref(
					&route,
					rooms_application::directory::NAME.as_bytes(),
					glowcap::CaptpVersion::V1_0,
				)
				.map_err(Failure::invalid)?;
				Ok(
					json!({"ok": true, "id": address.authority, "locator": address.address, "uri":uri, "transport": address.transport}),
				)
			}
			RequestBody::Tick { wait, after, after_id } => {
				if wait > 30 {
					return Err(Failure::invalid("wait must be 0..30 seconds"));
				}
				let deadline = tokio::time::Instant::now() + Duration::from_secs(wait);
				let mut updates = self.feed.inbox.updates();
				loop {
					let pending = self.pending(after_id).await?;
					let changed = after.is_some_and(|cursor| pending["cursor"].as_u64() != Some(cursor));
					if changed
						|| pending["pending"].as_array().is_some_and(|rows| !rows.is_empty())
						|| !pending["gap"].is_null()
						|| tokio::time::Instant::now() >= deadline
					{
						return Ok(pending);
					}
					tokio::select! {
						result = updates.changed() => result.map_err(Failure::uncertain)?,
						_ = tokio::time::sleep_until(deadline) => {},
					}
				}
			}
			RequestBody::Ack { ids } => self.feed.ack(ids).await,
			RequestBody::Resume {} => {
				self.pending(0).await?;
				app.workspace.resynchronize_discovery().await.map_err(peer_failure)?;
				self.feed.inbox.resume().await?;
				if self.observation.borrow().is_none() {
					*self.observation.borrow_mut() = Some(observe(self.feed.clone()));
				}
				Ok(json!({"ok": true, "observing": true, "notice": "listening resumed; directory snapshots requested"}))
			}
			RequestBody::Stop {} => Ok(json!({"ok": true})),
			RequestBody::Command { id, base, name, args } => {
				let status = self.commands.submit(&app.workspace, &id, base, &name, &args).await?;
				Ok(json!({"ok": true, "operation": id, "status":format!("{status:?}").to_lowercase()}))
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
				stop = matches!(request, RequestBody::Stop {});
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
		self.detach().await;
	}
	async fn detach(&self) {
		let observer = self.observation.borrow_mut().take();
		if let Some(observer) = observer {
			observer.stop.send_replace(true);
			if let Err(error) = observer.task.await {
				(self.report)(Failure::uncertain(error));
			}
		}
		self.feed.retire();
	}
	/// Drain callback and command use of the Host while retaining the control
	/// socket and journal lease through the peer's managed-store retirement.
	pub async fn drain(&self) -> Result<(), Failure> {
		self.acquisitions.close().await?;
		self.commands.close().await?;
		self.detach().await;
		Ok(())
	}
	pub async fn close(&mut self) -> Result<(), Failure> {
		self.drain().await?;
		let failed = self.feed.failure.borrow_mut().take();
		let gap = match failed {
			Some(error) => self.feed.inbox.gap(error).await,
			None => Ok(()),
		};
		// The retired journal still owns its directory lease. Hold it through
		// unlink so an old close cannot delete a replacement listener's socket.
		let Some(storage) = self.storage.take() else {
			return Ok(());
		};
		let storage = storage.close().await;
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
