//! Durable direct commands compose the session ledger with shared delivery.
//! The worker owns preparation, delivery and completion after observer loss.
mod execution;
mod worker;
use crate::{
	direct_events::EventReceiver,
	direct_outgoing::{Delivery, DirectOutgoing, Failure, Sent},
	direct_routes::RouteReceiver,
	directory_runtime::AcceptedDirect,
};
use crate::{platform::Platform, session_commands::SessionCommands};
pub use rooms_application::direct::operation::LineKey;
use rooms_application::{
	files::receiving::selection_fits,
	room::line::{MAX_LINE_BYTES, MAX_MESSAGE_FILES},
	session::state::OperationId,
};
use rooms_glowcap::client::sources::{Source, Sources};
use std::{cell::Cell, rc::Rc};
use tokio::sync::{mpsc, oneshot, watch};
pub use worker::CommandWorker;
const LIMIT: usize = 32;
const BYTES: usize = 66 * 1024 * 1024;
#[derive(Clone)]
pub struct Operation {
	pub id: OperationId,
	pub base: u64,
}
pub enum Command {
	Send {
		text: String,
		files: Vec<Source>,
	},
	Edit {
		line: LineKey,
		text: String,
	},
	Refile {
		line: LineKey,
		text: String,
		keep: Vec<u32>,
		files: Vec<Source>,
	},
	Withdraw {
		line: LineKey,
	},
}
#[derive(Debug, PartialEq, Eq)]
pub struct Committed {
	pub revision: u64,
	/// Repeating a committed operation does not recreate transient authority.
	pub sent: Option<Sent>,
}
/// Evidence about this operation's durable record, independent of delivery.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ledger {
	Unrecorded,
	Prepared,
	Committed,
	Abandoned,
	Unknown,
}
#[derive(Debug, PartialEq, Eq)]
pub struct CommandFailure {
	pub delivery: Delivery,
	pub ledger: Ledger,
	pub reason: String,
}
pub struct Reply {
	answer: oneshot::Receiver<Result<Committed, CommandFailure>>,
	ledger: Rc<Cell<Ledger>>,
	progress: Rc<Cell<Delivery>>,
	_permit: Rc<Permit>,
}
impl Reply {
	pub async fn wait(self) -> Result<Committed, CommandFailure> {
		self.answer.await.unwrap_or_else(|_| {
			Err(CommandFailure {
				delivery: self.progress.get(),
				ledger: self.ledger.get(),
				reason: "direct command worker ended without answering".into(),
			})
		})
	}
}
#[derive(Clone)]
pub struct DirectCommands {
	commands: SessionCommands,
	requests: mpsc::Sender<Request>,
	held: Rc<Cell<(usize, usize)>>,
	stop: watch::Sender<bool>,
	done: watch::Receiver<Option<Result<(), String>>>,
}
struct Permit {
	held: Rc<Cell<(usize, usize)>>,
	bytes: usize,
}
impl Drop for Permit {
	fn drop(&mut self) {
		let (count, bytes) = self.held.get();
		self.held.set((count - 1, bytes - self.bytes));
	}
}
struct Request {
	operation: Operation,
	context: AcceptedDirect,
	command: Command,
	answer: oneshot::Sender<Result<Committed, CommandFailure>>,
	ledger: Rc<Cell<Ledger>>,
	progress: Rc<Cell<Delivery>>,
	_permit: Rc<Permit>,
}
impl DirectCommands {
	/// Drive on the session LocalSet. This worker owns its outgoing worker;
	/// close it before SessionCommands, events, the source pool and transport.
	pub fn new<P: Platform>(
		platform: P,
		commands: SessionCommands,
		routes: RouteReceiver<P>,
		events: EventReceiver<P>,
		sources: Rc<Sources<P>>,
	) -> (Self, CommandWorker<P>) {
		let (delivery, delivery_worker) = DirectOutgoing::new(platform.clone(), routes, events, sources);
		let (requests, rx) = mpsc::channel(LIMIT);
		let (stop, stopping) = watch::channel(false);
		let (finished, done) = watch::channel(None);
		let owner = Self {
			commands: commands.clone(),
			requests,
			held: Default::default(),
			stop,
			done,
		};
		let worker = CommandWorker {
			platform,
			commands,
			delivery,
			delivery_worker: Some(delivery_worker),
			task: None,
			requests: rx,
			stopping,
			finished,
			pending: Vec::new(),
			queued: Vec::new(),
			cancel: watch::channel(false).0,
		};
		(owner, worker)
	}
	pub fn submit(
		&self,
		operation: Operation,
		context: &AcceptedDirect,
		mut command: Command,
	) -> Result<Reply, String> {
		if *self.stop.borrow() || self.requests.is_closed() {
			return Err("direct command owner is closed".into());
		}
		if !context.owned_by(&self.commands.view()) {
			return Err("the direct context belongs to another durable session".into());
		}
		command.bound()?;
		let bytes = command.bytes().saturating_add(operation.id.text().heap_bytes());
		let (count, held) = self.held.get();
		if count == LIMIT || bytes > BYTES.saturating_sub(held) {
			return Err("direct commands exceeded their count or byte ceiling".into());
		}
		let slot = self
			.requests
			.try_reserve()
			.map_err(|_| "direct command worker is unavailable")?;
		let permit = Rc::new(Permit {
			held: self.held.clone(),
			bytes,
		});
		self.held.set((count + 1, held + bytes));
		let progress = Rc::new(Cell::new(Delivery::NotSent));
		let ledger = Rc::new(Cell::new(Ledger::Unrecorded));
		let (answer, receive) = oneshot::channel();
		slot.send(Request {
			operation,
			context: context.clone(),
			command,
			answer,
			progress: progress.clone(),
			ledger: ledger.clone(),
			_permit: permit.clone(),
		});
		Ok(Reply {
			answer: receive,
			progress,
			ledger,
			_permit: permit,
		})
	}
	pub async fn close(&self) -> Result<(), String> {
		self.stop.send_replace(true);
		let mut done = self.done.clone();
		loop {
			if let Some(result) = done.borrow().clone() {
				return result;
			}
			done.changed()
				.await
				.map_err(|_| "direct command worker retired without completing shutdown")?;
		}
	}
}
impl Command {
	fn text(&self) -> &str {
		match self {
			Self::Send { text, .. } | Self::Edit { text, .. } | Self::Refile { text, .. } => text,
			Self::Withdraw { .. } => "",
		}
	}
	fn files(&self) -> &[Source] {
		match self {
			Self::Send { files, .. } | Self::Refile { files, .. } => files,
			_ => &[],
		}
	}
	fn take_files(&mut self) -> Vec<Source> {
		match self {
			Self::Send { files, .. } | Self::Refile { files, .. } => core::mem::take(files),
			_ => Vec::new(),
		}
	}
	fn bound(&mut self) -> Result<(), String> {
		if self.text().len() > MAX_LINE_BYTES || !selection_fits(self.files().iter().map(Source::description)) {
			return Err("direct command exceeds its text or attachment ceiling".into());
		}
		if let Self::Refile { keep, .. } = self {
			if keep.len() > MAX_MESSAGE_FILES {
				return Err("too many kept indices".into());
			}
			*keep = core::mem::take(keep).into_boxed_slice().into_vec();
		}
		match self {
			Self::Send { text, files } | Self::Refile { text, files, .. } => {
				*files = core::mem::take(files).into_boxed_slice().into_vec();
				*text = core::mem::take(text).into_boxed_str().into_string();
			}
			Self::Edit { text, .. } => *text = core::mem::take(text).into_boxed_str().into_string(),
			Self::Withdraw { .. } => {}
		}
		Ok(())
	}
	fn bytes(&self) -> usize {
		self.files().iter().fold(
			core::mem::size_of::<Request>() + self.text().len() + 4096,
			|bytes, file| {
				bytes
					.saturating_add(file.description().retained_bytes())
					.saturating_add(file.description().size())
			},
		)
	}
}
fn failed(delivery: Delivery, reason: &str) -> Failure {
	Failure {
		delivery,
		reason: rooms_application::failure::reason_prefix(reason).to_owned(),
	}
}
