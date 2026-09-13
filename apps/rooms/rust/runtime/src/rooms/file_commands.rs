//! Bounded room file commands. Admission retains the selected membership and
//! charges bytes before capture; accepted work outlives its caller's reply.
use super::*;
use crate::session::state::OrdinaryStatus;
use rooms_application::{
	room::{message::LineId, operation},
	session::state::{Inspection, OperationId, Outcome},
};
use rooms_glowcap::client::sources::Source;
use std::cell::Cell;

const REQUESTS: usize = 32;
const FILE_BYTES: usize = 64 * 1024 * 1024;
const METADATA_BYTES: usize = 2 * 1024 * 1024;

pub enum FileCommand {
	Send {
		caption: String,
		previews: rooms_application::open_graph::Selection,
		files: Vec<Source>,
	},
	Refile {
		line: u64,
		caption: String,
		keep: Vec<u32>,
		files: Vec<Source>,
	},
}
impl FileCommand {
	fn fields(&self) -> (&str, &[Source], &[u32]) {
		match self {
			Self::Send { caption, files, .. } => (caption, files, &[]),
			Self::Refile {
				caption, files, keep, ..
			} => (caption, files, keep),
		}
	}
	fn preview_bytes(&self) -> usize {
		match self {
			Self::Send { previews, .. } => previews.retained_bytes(),
			Self::Refile { .. } => 0,
		}
	}
	fn take_files(&mut self) -> Vec<Source> {
		match self {
			Self::Send { files, .. } | Self::Refile { files, .. } => std::mem::take(files),
		}
	}
	fn validate(&mut self) -> Result<(usize, usize), Error> {
		let (caption, files, keep) = self.fields();
		if caption.len() > rooms_application::room::line::MAX_LINE_BYTES
			|| keep.len() + files.len() > rooms_application::room::line::MAX_MESSAGE_FILES
			|| !rooms_application::files::receiving::selection_fits(files.iter().map(Source::description))
			|| keep.iter().enumerate().any(|(at, index)| keep[..at].contains(index))
		{
			return Err(Error::invalid("invalid room file caption or selection"));
		}
		if let Self::Refile { line, .. } = self {
			LineId::new(*line).ok_or_else(|| Error::invalid("invalid room line id"))?;
		}
		let preview_bytes = self.preview_bytes();
		// Normalize caller-owned spare capacity before retaining the request.
		let (caption, files, keep_bytes) = match self {
			Self::Send { caption, files, .. } => (caption, files, 0),
			Self::Refile {
				caption, files, keep, ..
			} => {
				*keep = std::mem::take(keep).into_boxed_slice().into_vec();
				(caption, files, keep.capacity() * std::mem::size_of::<u32>())
			}
		};
		*caption = std::mem::take(caption).into_boxed_str().into_string();
		*files = std::mem::take(files).into_boxed_slice().into_vec();
		Ok((
			files.iter().map(|file| file.description().size()).sum(),
			caption.capacity()
				+ preview_bytes
				+ keep_bytes + files.capacity() * std::mem::size_of::<Source>()
				+ files
					.iter()
					.map(|file| file.description().retained_bytes())
					.sum::<usize>(),
		))
	}
}

pub(super) struct Inputs {
	usage: Cell<(usize, usize, usize)>,
	active: Cell<usize>,
	/// `true` once the runtime closes, never before; the same polarity as
	/// every other owner's stop signal, so a guard reads `if *stopping`.
	closing: watch::Sender<bool>,
	changed: watch::Sender<()>,
}
impl Default for Inputs {
	fn default() -> Self {
		Self {
			usage: Cell::new((0, 0, 0)),
			active: Cell::new(0),
			closing: watch::channel(false).0,
			changed: watch::channel(()).0,
		}
	}
}
impl Inputs {
	fn reserve(self: &Rc<Self>, bytes: usize, metadata: usize) -> Result<Permit, Error> {
		let (count, held, meta) = self.usage.get();
		if *self.closing.borrow() {
			return Err(Error::closed("room file admission is closed"));
		}
		if count >= REQUESTS
			|| bytes > FILE_BYTES.saturating_sub(held)
			|| metadata > METADATA_BYTES.saturating_sub(meta)
		{
			return Err(Error::busy("room file requests exceed their retained budget"));
		}
		self.usage.set((count + 1, held + bytes, meta + metadata));
		Ok(Permit {
			owner: self.clone(),
			bytes,
			metadata,
			running: false,
		})
	}
	pub async fn close(&self) {
		self.closing.send_replace(true);
		let mut changed = self.changed.subscribe();
		while self.active.get() != 0 {
			if changed.changed().await.is_err() {
				break;
			}
		}
	}
}
struct Permit {
	owner: Rc<Inputs>,
	bytes: usize,
	metadata: usize,
	running: bool,
}
impl Drop for Permit {
	fn drop(&mut self) {
		let (count, bytes, metadata) = self.owner.usage.get();
		self.owner
			.usage
			.set((count - 1, bytes - self.bytes, metadata - self.metadata));
		if self.running {
			self.owner.active.set(self.owner.active.get() - 1);
		}
		self.owner.changed.send_replace(());
	}
}

struct Context<P: Platform> {
	conversation: String,
	directory: String,
	name: String,
	held: bool,
	link: Option<rooms_application::text::DocumentText>,
	publication: Option<rooms_application::text::DocumentText>,
	epoch: u64,
	room: Rc<Room<P>>,
	queue: Rc<tokio::sync::Mutex<()>>,
}
impl<P: Platform> Context<P> {
	fn current(&self, runtime: &RoomRuntime<P>) -> bool {
		if !runtime
			.shared
			.borrow()
			.rooms
			.get(&self.conversation)
			.is_some_and(|live| live.scope.current() && live.epoch == self.epoch && Rc::ptr_eq(&live.room, &self.room))
		{
			return false;
		}
		runtime
			.commands
			.view()
			.read(|state| {
				state.checkpoint().map(|checkpoint| {
					checkpoint.rooms().any(|room| {
						room.id.text().as_str() == Some(&self.conversation)
							&& room.directory.text().as_str() == Some(&self.directory)
							&& room.name.text().as_str() == Some(&self.name)
							&& room.held == self.held
							&& room.link.map(|link| link.text()) == self.link.as_ref()
							&& room.publication_id.map(|id| id.text()) == self.publication.as_ref()
					})
				})
			})
			.is_ok_and(|result| result.unwrap_or(false))
	}
}

pub struct FileAdmission<P: Platform> {
	runtime: RoomRuntime<P>,
	context: Context<P>,
	id: OperationId,
	base: u64,
	command: FileCommand,
	permit: Permit,
}
impl<P: Platform> RoomRuntime<P> {
	pub fn prepare_files(
		&self,
		id: OperationId,
		base: u64,
		conversation: &str,
		mut command: FileCommand,
	) -> Result<FileAdmission<P>, Error> {
		let (bytes, metadata) = command.validate()?;
		let state = self.shared.borrow();
		let live = connected(&state, conversation)?;
		let context = self.commands.view().read(|state| {
			let checkpoint = state.checkpoint()?;
			let intent = checkpoint
				.rooms()
				.find(|room| room.id.text().as_str() == Some(conversation))
				.ok_or_else(|| Error::stale("room is no longer intended"))?;
			if intent::Intent::read(intent).as_ref() != Some(&live.intent) {
				return Err(Error::stale("the live room no longer matches its intended context"));
			}
			Ok::<_, Error>(Context {
				conversation: conversation.into(),
				directory: intent
					.directory
					.text()
					.as_str()
					.ok_or_else(|| Error::invalid("room directory is not scalar text"))?
					.into(),
				name: intent
					.name
					.text()
					.as_str()
					.ok_or_else(|| Error::invalid("room name is not scalar text"))?
					.into(),
				held: intent.held,
				link: intent.link.map(|link| link.text().clone()),
				publication: intent.publication_id.map(|id| id.text().clone()),
				epoch: live.epoch,
				room: live.room.clone(),
				queue: live.file_queue.clone(),
			})
		})??;
		let metadata = metadata
			.saturating_add(2048)
			.saturating_add(id.text().heap_bytes())
			.saturating_add(context.conversation.capacity())
			.saturating_add(context.directory.capacity())
			.saturating_add(context.name.capacity())
			.saturating_add(context.link.as_ref().map_or(0, |v| v.heap_bytes()))
			.saturating_add(context.publication.as_ref().map_or(0, |v| v.heap_bytes()));
		let permit = self.file_inputs.reserve(bytes, metadata)?;
		Ok(FileAdmission {
			runtime: self.clone(),
			context,
			id,
			base,
			command,
			permit,
		})
	}
}
impl<P: Platform> FileAdmission<P> {
	/// The facade's answer task owns this future through completion. Closing the
	/// runtime refuses unstarted work and observes every retained admission.
	pub async fn run(mut self) -> Result<u64, Error> {
		let mut stopping = self.runtime.file_inputs.closing.subscribe();
		if *stopping.borrow() {
			return Err(Error::closed("room file commands are closed"));
		}
		self.permit.running = true;
		self.permit.owner.active.set(self.permit.owner.active.get() + 1);
		let queue = self.context.queue.clone();
		let _ordered = tokio::select! {
			biased;
			_ = stopping.changed() => return Err(Error::closed("room file preparation stopped")),
			guard = queue.lock() => guard,
		};
		let frozen = tokio::select! {
			biased;
			_ = stopping.changed() => return Err(Error::closed("room file preparation stopped")),
			result = crate::files::command_files::freeze(&self.runtime.platform, self.command.take_files()) => result?,
		};
		let identities = frozen.identities();
		let (caption, _, keep) = self.command.fields();
		let command = match &self.command {
			FileCommand::Send { previews, .. } => operation::Command::Send {
				caption,
				previews,
				files: &identities,
			},
			FileCommand::Refile { line, .. } => operation::Command::Refile {
				line: operation::Line {
					incarnation: self.runtime.incarnation,
					membership: self.context.epoch,
					id: LineId::new(*line).ok_or_else(|| Error::invalid("invalid line id"))?,
				},
				caption,
				keep,
				files: &identities,
			},
		};
		let material = command
			.material(operation::Context {
				directory: &self.context.directory,
				conversation: &self.context.conversation,
				room: &self.context.name,
				held: self.context.held,
				entry: self.context.held.then_some(self.context.link.as_ref()).flatten(),
			})
			.map_err(Error::invalid_by)?;
		let commands = &self.runtime.commands;
		let inspected = admission(commands.inspect_ordinary(self.id.clone(), self.base, material.clone())).await?;
		let Inspection::New(inspected) = inspected else {
			let Inspection::Committed(revision) = inspected else {
				unreachable!()
			};
			return Ok(revision);
		};
		if *stopping.borrow() || !self.context.current(&self.runtime) {
			return Err(Error::stale("room file context retired before preparation"));
		}
		if let OrdinaryStatus::Committed(revision) =
			admission(commands.prepare_inspected(inspected, material.clone())).await?
		{
			return Ok(revision);
		}
		let outcome = if *stopping.borrow() || !self.context.current(&self.runtime) {
			Err(Failure::NotApplied(Error::stale(
				"room file context retired before delivery",
			)))
		} else {
			match &self.command {
				FileCommand::Send { caption, previews, .. } => {
					self.runtime
						.send_files_with_previews(
							&self.context.conversation,
							caption,
							previews.clone(),
							frozen.into_sources(),
						)
						.await
				}
				FileCommand::Refile {
					line, caption, keep, ..
				} => {
					self.runtime
						.refile(&self.context.conversation, *line, caption, keep, frozen.into_sources())
						.await
				}
			}
		};
		match outcome {
			Ok(()) => admission(commands.commit_ordinary(self.id, material)).await,
			Err(Failure::Applied(cause)) => {
				admission(commands.commit_ordinary(self.id, material)).await?;
				Err(cause)
			}
			Err(Failure::NotApplied(cause)) => {
				admission(commands.resolve(self.id, Outcome::Abandoned)).await?;
				Err(cause)
			}
			Err(Failure::Unknown(cause)) => Err(Error::uncertain(format!("room file delivery is uncertain: {cause}"))),
		}
	}
}
async fn admission<T>(
	ticket: Result<crate::session::commands::Admission<T>, crate::session::commands::AdmissionError>,
) -> Result<T, Error> {
	ticket?.send()?.wait().await
}
