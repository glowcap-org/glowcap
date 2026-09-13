//! Bounded deferred grant commands. The worker owns persistence and replies;
//! the session behavior owns attached-view effects before callers are answered.
use crate::{
	Error,
	documents::Document,
	grants::DurableGrants,
	grants::publications::{Error as PublicationError, PublishedGrants},
};
use glowcap::{Argument, Behavior, CaptpVersion, Host, Locator, Resolver};
use rooms_application::grants::{
	Access, Change, Command,
	protocol::{self, GrantView},
};
use std::{
	cell::{Cell, RefCell},
	future::Future,
	rc::Rc,
};
use tokio::sync::{mpsc, oneshot, watch};

pub const MAX_PENDING_GRANT_COMMANDS: usize = 64;

pub enum GrantNotice<'a> {
	Committed { id: &'a str, change: Change },
	Unavailable,
	Routed,
}
pub trait GrantCommandEffects {
	/// The command may already be committed when its caller disappears. Report
	/// delivery failure without turning one lost caller into a service failure.
	fn reply_failed(&mut self, error: glowcap::Error);
	fn local_reply_failed(&mut self, error: Error);
	fn changed<D: Document>(
		&mut self,
		notice: GrantNotice<'_>,
		grants: &PublishedGrants<D>,
	) -> impl Future<Output = Result<(), Error>>;
}

enum Request {
	Route {
		locator: Locator,
		reply: oneshot::Sender<Result<(), Error>>,
	},
	Change {
		command: Command,
		reply: Reply,
	},
	Verify {
		swiss: Vec<u8>,
		reply: oneshot::Sender<Result<(), Error>>,
	},
}

enum Reply {
	Remote(Resolver),
	Local(oneshot::Sender<Result<Option<GrantView>, Error>>),
}

/// A full queue drains, so the same command can be admitted once it has. A
/// closed one never will. The caller acts on that difference.
fn queue_error<T>(error: mpsc::error::TrySendError<T>) -> Error {
	match error {
		mpsc::error::TrySendError::Full(_) => Error::busy("Rooms grant command queue is full"),
		mpsc::error::TrySendError::Closed(_) => Error::closed("Rooms grant command owner is closed"),
	}
}

pub struct GrantReply(oneshot::Receiver<Result<Option<GrantView>, Error>>);
impl GrantReply {
	pub async fn wait(self) -> Result<Option<GrantView>, Error> {
		self.0
			.await
			.map_err(|_| Error::closed("Rooms grant owner retired before completion"))?
	}
}

#[derive(Clone)]
pub struct GrantCommands {
	locator: Rc<RefCell<Locator>>,
	host: Host,
	tx: mpsc::Sender<Request>,
	admitting: Rc<Cell<bool>>,
	stop: watch::Sender<bool>,
	/// The worker's own completion, retained for every concurrent closer.
	done: watch::Receiver<Option<Result<(), Error>>>,
}

pub struct GrantCommandWorker<D: Document> {
	grants: PublishedGrants<D>,
	locator: Rc<RefCell<Locator>>,
	rx: mpsc::Receiver<Request>,
	admitting: Rc<Cell<bool>>,
	stop: watch::Receiver<bool>,
	done: watch::Sender<Option<Result<(), Error>>>,
}

impl GrantCommands {
	/// Restore before returning. The caller then drives `worker.run` on the
	/// Host's LocalSet and publishes its root as part of session startup.
	pub async fn open<D: Document>(
		grants: DurableGrants<D>,
		host: Host,
		root: [u8; Host::DURABLE_ENTROPY_BYTES],
		locator: Locator,
		mut session_behavior: impl FnMut() -> crate::grants::publications::GrantedBehavior + 'static,
	) -> Result<(Self, GrantCommandWorker<D>), PublicationError<D::Error>> {
		let (tx, rx) = mpsc::channel(MAX_PENDING_GRANT_COMMANDS);
		let (stop, stopping) = watch::channel(false);
		let (finished, done) = watch::channel(None);
		let admitting = Rc::new(Cell::new(false));
		let locator = Rc::new(RefCell::new(locator));
		let commands = Self {
			locator: locator.clone(),
			host: host.clone(),
			tx,
			admitting: admitting.clone(),
			stop,
			done,
		};
		let facets = commands.clone();
		let mut grants = PublishedGrants::new(grants, host, root, move || {
			let commands = facets.clone();
			let mut remaining = session_behavior();
			Box::new(move |authority, grant, verb, args| {
				commands
					.dispatch(grant.access(), verb, args)
					.unwrap_or_else(|| remaining(authority, grant, verb, args))
			})
		});
		grants.restore().await?;
		admitting.set(true);
		Ok((
			commands,
			GrantCommandWorker {
				grants,
				locator,
				rx,
				admitting,
				stop: stopping,
				done: finished,
			},
		))
	}
	/// Used by the enclosing root/facet dispatcher, which owns the held access.
	/// No argument can claim administrator authority or enter the worker as a cap.
	pub fn dispatch(&self, access: Access, verb: &str, args: &[Argument]) -> Option<Result<Argument, String>> {
		if !matches!(verb, protocol::ISSUE | protocol::SET_POLICY | protocol::REVOKE) {
			return None;
		}
		if args.len() > 5 {
			return Some(Err(
				Error::invalid("invalid Rooms grant command arguments").into_refusal()
			));
		}
		let mut views = [rooms_glowcap::Value(&Argument::Void); 5];
		for (view, value) in views.iter_mut().zip(args) {
			*view = rooms_glowcap::Value(value);
		}
		let command = protocol::read(access, verb, &views[..args.len()])?;
		// The wire form of `change` below. Each failure is classed the same way
		// there, and this is the one place the class becomes refusal text.
		Some(
			(|| {
				if !self.admitting.get() {
					return Err(Error::closed("Rooms grant command owner is closed"));
				}
				let command = command.map_err(Error::grant_view)?.admit().map_err(Error::ledger)?;
				let permit = self.tx.try_reserve().map_err(queue_error)?;
				let reply = self.host.defer_turn().map_err(Error::from)?;
				permit.send(Request::Change {
					command,
					reply: Reply::Remote(reply),
				});
				Ok(Argument::Void)
			})()
			.map_err(Error::into_refusal),
		)
	}
	/// Trusted local admission shares the same serial persistence worker.
	pub fn change(&self, command: Command) -> Result<GrantReply, Error> {
		let command = command.admit().map_err(Error::ledger)?;
		if !self.admitting.get() {
			return Err(Error::closed("Rooms grant command owner is closed"));
		}
		let slot = self.tx.try_reserve().map_err(queue_error)?;
		let (reply, receive) = oneshot::channel();
		slot.send(Request::Change {
			command,
			reply: Reply::Local(reply),
		});
		Ok(GrantReply(receive))
	}
	pub async fn verify_name(&self, swiss: Vec<u8>) -> Result<(), Error> {
		if swiss.len() > 16_384 {
			return Err(Error::invalid("Rooms grant verification name exceeds its bound"));
		}
		if !self.admitting.get() {
			return Err(Error::closed("Rooms grant command owner is closed"));
		}
		let (reply, receive) = oneshot::channel();
		self.tx
			.try_send(Request::Verify {
				swiss: swiss.into_boxed_slice().into_vec(),
				reply,
			})
			.map_err(queue_error)?;
		receive
			.await
			.map_err(|_| Error::closed("Rooms grant owner retired before verification"))?
	}
	/// The application supplies the reachability hints it prepared for Share.
	pub(crate) async fn publication_route(&self, locator: &Locator) -> Result<(), Error> {
		{
			let held = self.locator.borrow();
			if held.transport != locator.transport || held.designator != locator.designator {
				return Err(Error::invalid("grant publication route belongs to another identity"));
			}
		}
		if !self.admitting.get() {
			return Err(Error::closed("Rooms grant command owner is closed"));
		}
		let (reply, receive) = oneshot::channel();
		self.tx
			.try_send(Request::Route {
				locator: locator.clone(),
				reply,
			})
			.map_err(queue_error)?;
		receive
			.await
			.map_err(|_| Error::closed("Rooms grant owner retired before publication"))?
	}
	pub(crate) fn views<D: Document>(&self, grants: &PublishedGrants<D>) -> Result<Vec<GrantView>, Error> {
		grant_views(grants, &self.locator.borrow())
	}

	/// Only the grant-administration methods. A complete session root delegates
	/// recognized methods through dispatch and owns the remaining session verbs.
	pub fn admin_behavior(&self) -> Behavior {
		let commands = self.clone();
		Box::new(move |verb, args| {
			commands
				.dispatch(Access::Admin, verb, args)
				.unwrap_or_else(|| Err(Error::invalid("unknown Rooms grant verb").into_refusal()))
		})
	}
	/// Stop admission immediately; the worker drains already admitted commands,
	/// then closes publications. Concurrent and repeated callers share one result.
	pub async fn close(&self) -> Result<(), Error> {
		self.admitting.set(false);
		self.stop.send_replace(true);
		let mut done = self.done.clone();
		loop {
			if let Some(result) = done.borrow().clone() {
				return result;
			}
			done.changed()
				.await
				.map_err(|_| Error::closed("Rooms grant worker disappeared"))?;
		}
	}
}

impl<D: Document> GrantCommandWorker<D> {
	pub fn views(&self) -> Result<Vec<GrantView>, Error> {
		grant_views(&self.grants, &self.locator.borrow())
	}
	/// This future owns the worker. Cancellation drops publication authority
	/// and all deferred replies; storage adapters retain admitted operations
	/// and their leases until they finish. A cancelled worker cannot be reused against uncertain state.
	pub async fn run(mut self, mut notices: impl GrantCommandEffects) -> Result<(), Error> {
		let result = self.drive(&mut notices).await;
		self.admitting.set(false);
		let cleanup = self.grants.close().map_err(Error::storage);
		let notice = notices.changed(GrantNotice::Unavailable, &self.grants).await;
		let result = Error::fold(Error::fold(result, cleanup), notice);
		self.done.send_replace(Some(result.clone()));
		result
	}
	async fn drive(&mut self, notices: &mut impl GrantCommandEffects) -> Result<(), Error> {
		loop {
			if *self.stop.borrow() {
				self.rx.close();
			}
			let request = tokio::select! {
				value = self.rx.recv() => match value { Some(value) => value, None => return Ok(()) },
				_ = self.stop.changed(), if !self.rx.is_closed() => continue,
			};
			self.execute(request, notices).await?;
		}
	}
	async fn execute(&mut self, request: Request, notices: &mut impl GrantCommandEffects) -> Result<(), Error> {
		let (command, reply) = match request {
			Request::Change { command, reply } => (command, reply),
			Request::Route { locator, reply } => {
				let outcome = match grant_views(&self.grants, &locator) {
					Ok(_) => {
						*self.locator.borrow_mut() = locator;
						notices.changed(GrantNotice::Routed, &self.grants).await
					}
					Err(error) => Err(error),
				};
				if let Err(Err(error)) = reply.send(outcome) {
					notices.local_reply_failed(error);
				}
				return Ok(());
			}
			Request::Verify { swiss, reply } => {
				let _ = reply.send(self.grants.verify_name(&swiss));
				return Ok(());
			}
		};
		let (id, revoke) = match &command {
			Command::Issue { id, .. } | Command::SetPolicy { id, .. } => (id.clone(), false),
			Command::Revoke { id } => (id.clone(), true),
		};
		let result = self.grants.apply(command).await;
		let change = match &result {
			Ok(change) => Some(*change),
			Err(PublicationError::Publication { change, .. }) => *change,
			_ => None,
		};
		let notice = if let Some(change) = change {
			notices
				.changed(GrantNotice::Committed { id: &id, change }, &self.grants)
				.await
		} else {
			Ok(())
		};
		let usable = self.grants.grants().is_ok();
		let answer = result.map_err(Error::grant).and_then(|_| {
			if revoke {
				return Ok(None);
			}
			let name = self
				.grants
				.swiss(&id)
				.map_err(Error::grant)?
				.ok_or_else(|| Error::stale("grant is no longer published"))?;
			// Rooms persists one base64url spelling, independent of live CapTP.
			let link = glowcap::format_sturdyref(&self.locator.borrow(), name.as_bytes(), CaptpVersion::V1_0)
				.map_err(Error::from)?;
			let ledger = self.grants.grants().map_err(Error::grant)?;
			let grant = ledger
				.get(&id)
				.map_err(Error::ledger)?
				.ok_or_else(|| Error::stale("grant disappeared"))?;
			GrantView::from_grant(grant, link).map(Some).map_err(Error::grant_view)
		});
		let answer = match (answer, notice) {
			(Ok(value), Ok(())) => Ok(value),
			(Err(error), Ok(())) => Err(error),
			// The policy stands. Asking again would issue a second grant, so the
			// caller must read the ledger rather than retry the command.
			(Ok(_), Err(notice)) => {
				Err(Error::uncertain("grant policy committed but attached views were not notified").retain(notice))
			}
			(Err(error), Err(notice)) => Err(error.retain(notice)),
		};
		match reply {
			Reply::Remote(mut reply) => {
				let answer = answer.and_then(|view| match view {
					Some(view) => view.encode().map(Argument::String).map_err(Error::invalid_by),
					None => Ok(Argument::Void),
				});
				let delivery = match answer {
					Ok(value) => reply.fulfill(&value),
					Err(error) => reply.break_with(&error.into_refusal()),
				};
				if let Err(error) = delivery {
					notices.reply_failed(error);
				}
			}
			Reply::Local(reply) => {
				if let Err(Err(error)) = reply.send(answer) {
					notices.local_reply_failed(error);
				}
			}
		}

		if usable {
			Ok(())
		} else {
			// The ledger no longer reads back, so no later command can be
			// admitted against it until recovery has run.
			Err(Error::uncertain(
				"Rooms grant storage requires recovery; command owner stopped",
			))
		}
	}
}

pub fn grant_views<D: Document>(grants: &PublishedGrants<D>, locator: &Locator) -> Result<Vec<GrantView>, Error> {
	let ledger = grants.grants().map_err(Error::grant)?;
	let mut views = Vec::with_capacity(ledger.active_count().map_err(Error::ledger)?);
	for grant in ledger
		.records()
		.map_err(Error::ledger)?
		.filter(|grant| !grant.revoked())
	{
		let Some(name) = grants.swiss(grant.id()).map_err(Error::grant)? else {
			continue;
		};
		let link = glowcap::format_sturdyref(locator, name.as_bytes(), CaptpVersion::V1_0)?;
		views.push(GrantView::from_grant(grant, link).map_err(Error::grant_view)?);
	}
	Ok(views)
}

impl<D: Document> Drop for GrantCommandWorker<D> {
	fn drop(&mut self) {
		self.admitting.set(false);
		if self.done.borrow().is_none() {
			self.done
				.send_replace(Some(Err(Error::closed("Rooms grant worker was cancelled"))));
		}
	}
}
