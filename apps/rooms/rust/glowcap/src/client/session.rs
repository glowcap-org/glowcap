//! Client of a Rooms session capability. The attached browser and native
//! consumers use the same protocol; transport acquisition stays with Runtime.
use super::{Client, Deadline};
use crate::{routes::CheckpointRoutes, Value};
use glowcap::{Argument, Ref};
use rooms_application::{
	grants::Access,
	room::ArgumentView,
	session::{command, snapshot::Snapshot, verbs},
};
use std::{cell::RefCell, rc::Rc};

mod archive_shares;
pub mod controller;
mod error;
mod files;
mod grants;
mod operator;
pub use archive_shares::SharedHistory;
pub use error::Error;
pub use files::{FileMessage, HistoryView, Refile};
pub use grants::{Facet, GrantPatch};
pub use rooms_application::archive::change::Change as HistoryChange;
pub use rooms_application::session::event::Event;

#[derive(Clone)]
pub struct Session<D> {
	client: Client<D>,
	reference: Ref,
}
/// Synchronous delivery transfers admitted data and file custody to the
/// application. Separate methods avoid allocating an envelope per notice.
pub trait Observer {
	fn changed(&mut self, snapshot: Snapshot) -> Result<(), String>;
	fn event(&mut self, event: Event<Ref>) -> Result<(), String>;
	fn operations_changed(&mut self, scope: &str) -> Result<(), String>;
	fn history_changed(&mut self, change: HistoryChange) -> Result<(), String>;
}
type Observed = RefCell<Box<dyn Observer>>;

/// Holds the local observer and its connection. Dropping it releases callback
/// captures immediately; a retained remote observer then refuses delivery.
/// The wire has no unwatch verb. The service retires a refused observer or its
/// closed connection; this handle does not claim remote retirement on Drop.
pub struct Watch<D> {
	_client: Client<D>,
	_observer: Ref,
	_callback: Rc<Observed>,
}
impl<D: Deadline> Session<D> {
	pub fn new(client: Client<D>, reference: Ref) -> Self {
		Self { client, reference }
	}
	pub async fn enliven(client: Client<D>, link: &str) -> Result<Self, Error> {
		let reference = client.enliven(link).await?;
		Ok(Self::new(client, reference))
	}
	pub fn client(&self) -> &Client<D> {
		&self.client
	}
	pub fn reference(&self) -> &Ref {
		&self.reference
	}
	pub async fn snapshot(&self) -> Result<Snapshot, Error> {
		let reply = self.call(verbs::SNAPSHOT, &[]).await?;
		read_snapshot(&reply)
	}
	pub async fn command(&self, operation: &str, base: u64, name: &str, arguments: &[String]) -> Result<u64, Error> {
		// Bound before retaining the wire material. The shared request parser
		// then validates names and shapes; the remote facet still owns rights.
		if arguments.len() > command::MAX_ARGUMENTS {
			return Err(Error::Input(command::Refusal::Count));
		}
		if arguments
			.iter()
			.map(String::len)
			.try_fold(name.len(), usize::checked_add)
			.is_none_or(|n| n > command::MAX_MATERIAL_BYTES)
		{
			return Err(Error::Input(command::Refusal::MaterialSize));
		}
		let mut args = transaction(operation, base)?;
		args.reserve(1 + arguments.len());
		args.push(name.into());
		args.extend(arguments.iter().cloned().map(Argument::String));
		command::Request::read(Access::Admin, &args.iter().map(Value).collect::<Vec<_>>())?;
		revision(&self.call(verbs::COMMAND, &args).await?)
	}
	pub async fn replace_checkpoint(
		&self,
		operation: &str,
		base: u64,
		checkpoint: &rooms_application::session::checkpoint::Checkpoint,
	) -> Result<u64, Error> {
		self.checkpoint(verbs::REPLACE_CHECKPOINT, operation, base, checkpoint)
			.await
	}
	pub async fn adopt_workspace(
		&self,
		operation: &str,
		base: u64,
		checkpoint: &rooms_application::session::checkpoint::Checkpoint,
	) -> Result<u64, Error> {
		self.checkpoint(verbs::ADOPT_WORKSPACE, operation, base, checkpoint)
			.await
	}
	async fn checkpoint(
		&self,
		verb: &'static str,
		operation: &str,
		base: u64,
		checkpoint: &rooms_application::session::checkpoint::Checkpoint,
	) -> Result<u64, Error> {
		let mut args = transaction(operation, base)?;
		let document = checkpoint
			.encode_for(Access::Admin)
			.map_err(|_| Error::Reply("invalid Rooms checkpoint"))?;
		args.push(document.into());
		revision(&self.call(verb, &args).await?)
	}
	pub async fn typing(&self, conversation: &str, on: bool) -> Result<(), Error> {
		self.call(verbs::TYPING, &[conversation.into(), on.into()]).await?;
		Ok(())
	}
	pub async fn resolve_effect(&self, operation: &str, committed: bool) -> Result<(), Error> {
		self.call(
			verbs::RESOLVE_EFFECT,
			&[
				operation.into(),
				if committed { "committed" } else { "abandoned" }.into(),
			],
		)
		.await?;
		Ok(())
	}
	pub async fn resume_effect(&self, operation: &str) -> Result<u64, Error> {
		revision(&self.call(verbs::RESUME_EFFECT, &[operation.into()]).await?)
	}
	pub async fn bridge_form(&self, conversation: &str) -> Result<Option<rooms_application::bridge::Form>, Error> {
		let reply = self.call(verbs::ROOM_BRIDGE_FORM, &[conversation.into()]).await?;
		rooms_application::bridge::read_form(&Value(&reply))
			.map_err(super::Error::from)
			.map_err(Error::from)
	}
	async fn call(&self, verb: &'static str, args: &[Argument]) -> Result<Argument, Error> {
		Ok(self
			.client
			.call(&self.reference, verb, args, "the Rooms session did not answer")
			.await?
			.0)
	}
}
impl<D: Deadline + Clone + 'static> Session<D> {
	pub async fn watch(&self, observer: impl Observer + 'static) -> Result<(Snapshot, Watch<D>), Error> {
		let callback: Rc<Observed> = Rc::new(RefCell::new(Box::new(observer)));
		let weak = Rc::downgrade(&callback);
		let observer = self
			.client
			.session()
			.spawn_owned(move |verb, args| {
				let callback = weak.upgrade().ok_or("Rooms session observer retired")?;
				let mut callback = callback.try_borrow_mut().map_err(|_| "Rooms observer was reentered")?;
				match verb {
					rooms_application::session::CHANGED => {
						callback.changed(read_snapshot_args(args).map_err(|e| e.to_string())?)?
					}
					rooms_application::session::EVENT => {
						if args.len() > rooms_application::session::event::MAX_FIELDS {
							return Err(rooms_application::session::event::Refusal::Shape.to_string());
						}
						callback.event(
							Event::read(&args.iter().map(Value).collect::<Vec<_>>()).map_err(|e| e.to_string())?,
						)?
					}
					rooms_application::session::OPERATIONS_CHANGED => match args {
						[Argument::String(scope)] if scope.encode_utf16().take(65537).count() <= 65536 => {
							callback.operations_changed(scope)?
						}
						_ => return Err("invalid Rooms operations invalidation".into()),
					},
					rooms_application::session::HISTORY_CHANGED => {
						if args.len() > 3 {
							return Err("invalid Rooms history invalidation".into());
						}
						callback.history_changed(
							HistoryChange::read(&args.iter().map(Value).collect::<Vec<_>>())
								.map_err(|e| e.to_string())?,
						)?;
					}
					_ => return Err("unknown Rooms session observer method".into()),
				};
				Ok(Argument::Void)
			})
			.map_err(super::Error::from)?;
		let watch = Watch {
			_client: self.client.clone(),
			_observer: observer.clone(),
			_callback: callback,
		};
		let reply = self.call(verbs::WATCH, &[observer.into()]).await?;
		Ok((read_snapshot(&reply)?, watch))
	}
}
fn read_snapshot(reply: &Argument) -> Result<Snapshot, Error> {
	read_snapshot_args(
		reply
			.as_list()
			.ok_or(Error::Reply("the Rooms session answered no snapshot"))?,
	)
}
fn read_snapshot_args(args: &[Argument]) -> Result<Snapshot, Error> {
	if args.len() != rooms_application::session::snapshot::WIRE_FIELDS {
		return Err(rooms_application::session::snapshot::Refusal::Shape.into());
	}
	Ok(Snapshot::read(
		&args.iter().map(Value).collect::<Vec<_>>(),
		&CheckpointRoutes,
	)?)
}
fn revision(reply: &Argument) -> Result<u64, Error> {
	Value(reply)
		.integer()
		.and_then(|n| u64::try_from(n).ok())
		.filter(|n| *n < (1 << 53))
		.ok_or(Error::Reply("the Rooms session answered an invalid revision"))
}

fn transaction(operation: &str, base: u64) -> Result<Vec<Argument>, Error> {
	if !rooms_application::session::state::OperationId::accepts_utf16(operation.encode_utf16()) {
		return Err(command::Refusal::OperationId.into());
	}
	if rooms_application::fields::SafeInteger::<false>::new(base).is_none() {
		return Err(command::Refusal::Arguments.into());
	}
	Ok(vec![operation.into(), Argument::Integer(base as i64)])
}
