//! One writer for saved operator choices. The worker owns accepted commands
//! through disk I/O and runtime installation, even after their caller leaves.
//! Shutdown closes admission and drains the commands before retiring sockets.
use super::super::{error::Error, notice::Notice, state::State};
use futures_util::{StreamExt, stream::FuturesUnordered};
use glowcap::{Argument, current_session};
use rooms_application::{
	documents::WriteFailure,
	server::operations::document::{Document, FILE, MAX_BYTES},
};
use rooms_platform::storage::{self, Directory};
use std::{future::Future, path::PathBuf, pin::Pin, rc::Rc, sync::Arc};
use tokio::sync::{Mutex, mpsc, watch};

type Outcome = Result<Argument, String>;
type Pending<'a, T> = Pin<Box<dyn Future<Output = T> + 'a>>;
type Command = Box<dyn FnOnce(Store) -> Pending<'static, ()>>;
const QUEUE: usize = 64;

pub(crate) struct Handle {
	commands: mpsc::Sender<Command>,
	stop: watch::Sender<bool>,
}

pub(crate) struct Writer {
	commands: mpsc::Receiver<Command>,
	store: Store,
	stop: watch::Receiver<bool>,
}

/// Available only inside worker-owned commands. Socket preparation happens
/// before change(). Only persistence and synchronous installation serialize.
#[derive(Clone)]
pub(crate) struct Store(Rc<Mutex<Data>>);
struct Data {
	committed: Document,
	directory: Option<Arc<Directory>>,
	uncertain: bool,
}

pub(crate) fn open(document: Document, directory: Option<Arc<Directory>>) -> (Handle, Writer) {
	let (commands, receiver) = mpsc::channel(QUEUE);
	let (stop, stopping) = watch::channel(false);
	(
		Handle { commands, stop },
		Writer {
			commands: receiver,
			store: Store(Rc::new(Mutex::new(Data {
				committed: document,
				directory,
				uncertain: false,
			}))),
			stop: stopping,
		},
	)
}

impl Handle {
	pub fn stop(&self) {
		self.stop.send_replace(true);
	}

	/// Reserve before deferring the served turn. The worker, rather than the
	/// caller's future, owns every admitted command and its answer.
	pub fn later<F>(&self, state: &State, verb: &'static str, work: F) -> Outcome
	where
		F: FnOnce(Store) -> Pending<'static, Outcome> + 'static,
	{
		if *self.stop.borrow() {
			return Err("the server is stopping".into());
		}
		let seat = self
			.commands
			.try_reserve()
			.map_err(|_| "the operations writer is busy; try again")?;
		let session = current_session()
			.map_err(|e| e.to_string())?
			.ok_or("an operator change is reachable only over a session")?
			.borrowed();
		let mut answer = session.host().defer_turn().map_err(|e| e.to_string())?;
		let report = state.reporter();
		seat.send(Box::new(move |writer| {
			Box::pin(async move {
				let outcome = work(writer).await;
				let delivery = match outcome {
					Ok(value) => answer.fulfill_value(&value),
					Err(reason) => answer.break_with(&reason),
				};
				if let Err(cause) = delivery
					&& session.is_open()
				{
					report(Notice::AnswerUndeliverable { verb, cause });
				}
			})
		}));
		Ok(Argument::Void)
	}
}

impl Writer {
	pub fn store(&self) -> Store {
		self.store.clone()
	}
	pub async fn run(mut self) {
		let mut pending = FuturesUnordered::new();
		let (mut stopping, mut drained) = (false, false);
		loop {
			if drained && pending.is_empty() {
				return;
			}
			tokio::select! {
				biased;
				_ = self.stop.changed(), if !stopping => { self.commands.close(); stopping = true; }
				_ = pending.next(), if !pending.is_empty() => {},
				command = self.commands.recv(), if !drained && pending.len() < QUEUE => match command {
					Some(command) => pending.push(command(self.store.clone())),
					None => drained = true,
				}
			}
		}
	}
}

impl Store {
	pub async fn snapshot(&self) -> Document {
		self.0.lock().await.committed.clone()
	}
	pub async fn change<T>(
		&self,
		prepare: impl FnOnce(&Document) -> Result<Document, String>,
		commit: impl FnOnce(&Document) -> T,
	) -> Result<T, String> {
		let mut data = self.0.lock().await;
		if data.uncertain {
			return Err("the operations document requires restart reconciliation".into());
		}
		let next = prepare(&data.committed)?;
		if next != data.committed {
			data.install(next).await?;
		}
		Ok(commit(&data.committed))
	}
}

impl Data {
	/// Candidates are prepared inside the serialized command from the last
	/// committed snapshot. Memory advances only after a confirmed replacement.
	async fn install(&mut self, document: Document) -> Result<(), String> {
		if self.uncertain {
			return Err("the operations document requires restart reconciliation".into());
		}
		let mut text = document.encode().map_err(|e| e.to_string())?;
		text.push('\n');
		if let Some(directory) = self.directory.clone() {
			match tokio::task::spawn_blocking(move || storage::atomic::replace(&directory, FILE, [text.as_bytes()]))
				.await
			{
				Ok(Ok(())) => {}
				Ok(Err(WriteFailure::Unchanged(error))) => {
					return Err(format!("keeping the operations document failed: {error}"));
				}
				Ok(Err(WriteFailure::Indeterminate(error))) => {
					self.uncertain = true;
					return Err(format!(
						"the operations write is uncertain; restart to reconcile it: {error}"
					));
				}
				Err(error) => {
					self.uncertain = true;
					return Err(format!(
						"the operations writer failed; restart to reconcile it: {error}"
					));
				}
			}
		}
		self.committed = document;
		Ok(())
	}
}

/// Read under the server's state-directory lease, off the capability executor.
pub(crate) async fn read(directory: Option<PathBuf>) -> Result<Document, Error> {
	tokio::task::spawn_blocking(move || {
		let Some(directory) = directory else {
			return Ok(Document::default());
		};
		let Some(bytes) = storage::read(&directory.join(FILE), MAX_BYTES + 1)? else {
			return Ok(Document::default());
		};
		let text = std::str::from_utf8(&bytes).map_err(|_| {
			Error::Operations(rooms_application::server::operations::document::Error::Json(
				"not UTF-8".into(),
			))
		})?;
		Document::decode(text.strip_prefix('\u{feff}').unwrap_or(text)).map_err(Error::Operations)
	})
	.await
	.map_err(|error| Error::Worker(error.to_string()))?
}
