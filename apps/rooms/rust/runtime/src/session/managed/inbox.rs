//! One callback worker retains bounded input until current source admission.
//! Its owner cancels and drains the worker before releasing the actor root.
use glowcap::{Argument, Host, Ref, Result, loam};
use rooms_application::content::session::workspace::{DiscoverySelection, InboxSelection};
use rooms_glowcap::client::{Deadline, Tasks, workspace::Workspace};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};
use tokio::sync::{mpsc, watch};
mod custody;
use custody::{Charge, demand};

/// Shared identity of an installed callback. Child line actors recheck this
/// exact source and callback, including retirement before workspace reconciliation.
#[derive(Clone)]
pub struct InboxOrigin(Rc<Origin>);
struct Origin {
	source: Ref,
	selected: Selection,
	installed: Ref,
	live: std::rc::Weak<Live>,
	recording: RefCell<Option<crate::archive::session::Destination>>,
	// One ordinal per installed callback orders retained reciprocal handoffs.
	// Its fresh inbox slot separates lifetimes; custody generations persist the
	// committed ordinal so an older retry cannot select a newer route's key.
	next_route: Cell<i64>,
}
enum Selection {
	Installed(InboxSelection),
	Discovery(DiscoverySelection),
}
impl InboxOrigin {
	/// Capture may outlive the installed inbox. Charge its entire shared body
	/// per capture rather than relying on another owner's continued admission.
	pub(super) fn retained_bytes(&self) -> usize {
		core::mem::size_of::<Origin>()
			+ 2 * core::mem::size_of::<usize>()
			+ match &self.0.selected {
				Selection::Installed(s) => s.retained_bytes() - core::mem::size_of::<InboxSelection>(),
				Selection::Discovery(_) => 0,
			}
	}
	/// Valid only inside the synchronous consumer immediately following fresh
	/// source admission. It is cleared before callback resolution or any wait.
	pub(super) fn recording_destination(&self) -> Option<crate::archive::session::Destination> {
		self.0.recording.borrow().clone()
	}
	pub(in crate::session::managed) fn installed(&self) -> Option<(&InboxSelection, &Ref)> {
		match &self.0.selected {
			Selection::Installed(selected) => Some((selected, &self.0.installed)),
			Selection::Discovery(_) => None,
		}
	}
	pub fn source(&self) -> &Ref {
		&self.0.source
	}
	pub fn is_open(&self) -> bool {
		self.0.live.upgrade().is_some_and(|live| !live.closed.get())
	}
	pub(super) fn route_ordinal(&self) -> Result<i64> {
		let ordinal = self.0.next_route.get();
		let next = ordinal
			.checked_add(1)
			.ok_or_else(|| loam::refusal("direct route ordinal exhausted"))?;
		self.0.next_route.set(next);
		Ok(ordinal)
	}
	/// Queued events keep their exact selection and initiating endpoint.
	pub async fn check<P: Deadline + Clone>(&self, host: &Host, platform: P) -> Result<()> {
		if !self.admitted(host, platform).await? {
			return Err(loam::refusal("original callback is unavailable"));
		}
		Ok(())
	}
	/// A refused source is unavailable. A missed answer retains the consumer's
	/// cursor for retry rather than silently discarding the queued occurrence.
	pub(super) async fn admitted<P: Deadline + Clone>(&self, host: &Host, platform: P) -> Result<bool> {
		if !self.is_open() {
			return Ok(false);
		}
		let workspace = Workspace::local(host.clone(), platform, self.source().clone());
		let live = self
			.0
			.live
			.upgrade()
			.ok_or_else(|| loam::refusal("callback owner closed"))?;
		let writer = live
			.budget
			.writer
			.upgrade()
			.ok_or_else(|| loam::refusal("callback owner closed"))?;
		let owner = writer.root()?;
		let result = match &self.0.selected {
			Selection::Installed(selected) => workspace.owner_check_inbox(&owner, selected, &self.0.installed).await,
			Selection::Discovery(selected) => workspace.owner_check_discovery(&owner, selected).await,
		};
		match result {
			Ok(()) => Ok(self.is_open()),
			Err(rooms_glowcap::client::Error::Binding(error) | rooms_glowcap::client::Error::Unsent(error))
				if error.kind() == glowcap::ErrorKind::Broken =>
			{
				Ok(false)
			}
			Err(error) => Err(loam::refusal(error.to_string())),
		}
	}
}
#[derive(Clone, Copy)]
enum Kind {
	Notification,
	Direct,
	Line,
}
enum Admission<P> {
	Discovery {
		workspace: Workspace<P>,
		selected: DiscoverySelection,
		synchronized: watch::Receiver<bool>,
	},
	Install {
		workspace: Workspace<P>,
		selected: InboxSelection,
	},
	Child {
		workspace: Workspace<P>,
		origin: InboxOrigin,
	},
}

const QUEUED_PER_INBOX: usize = 16;
const MAX_INBOXES: usize = 2 * rooms_application::content::session::workspace::MAX_DIRECTORIES
	+ rooms_application::content::session::workspace::MAX_CONVERSATIONS;

/// The session shares these limits across every callback, including waits in
/// source admission. A peer cannot multiply the payload budget by room count.
pub(super) struct Budget {
	admission: RefCell<super::incoming::Admission>,
	writer: std::rc::Weak<super::executor::Writer>,
	inboxes: Cell<usize>,
	custody: Rc<custody::Budget>,
}
impl Budget {
	pub(super) fn new(writer: std::rc::Weak<super::executor::Writer>) -> Self {
		Self {
			admission: RefCell::new(super::incoming::Admission::new(
				rooms_application::admission::Settings::defaults(
					rooms_application::admission::SESSION_ROWS,
					rooms_application::admission::POOLED_AGGREGATE_SCALE,
				),
			)),
			writer,
			inboxes: Cell::new(0),
			custody: Rc::new(custody::Budget::default()),
		}
	}
	pub(super) fn configure_admission(&self, settings: rooms_application::admission::Settings) -> Result<()> {
		if self.inboxes.get() != 0 {
			return Err(loam::refusal("incoming policy is already in use"));
		}
		*self.admission.borrow_mut() = super::incoming::Admission::new(settings);
		Ok(())
	}
	pub(super) fn active(&self) -> usize {
		self.inboxes.get()
	}
}
struct Failure {
	first: glowcap::Error,
	count: usize,
}
struct Pending {
	verb: &'static str,
	args: Vec<Argument>,
	delivering: Option<glowcap::Session>,
	resolver: Option<glowcap::Resolver>,
	_charge: Charge,
}
struct Live {
	budget: Rc<Budget>,
	closed: Cell<bool>,
	active: Cell<bool>,
	refused: Cell<usize>,
}
impl Live {
	fn retire(&self) {
		if self.active.replace(false) {
			self.budget.inboxes.set(self.budget.inboxes.get() - 1);
		}
	}
}
impl Drop for Live {
	fn drop(&mut self) {
		self.retire();
	}
}

/// Retain this owner through workspace installation, receipt recovery and live
/// subscription. Dropping it cancels queued admission and breaks pending calls.
/// A retained remote reference then refuses without retaining new input.
pub struct Inbox<P: Tasks> {
	task: Option<P::Task>,
	reference: Ref,
	live: Rc<Live>,
	stop: watch::Sender<bool>,
	ended: watch::Receiver<bool>,
	failure: Rc<RefCell<Option<Failure>>>,
	origin: InboxOrigin,
	publication: Option<(Host, String)>,
}
impl<P: Tasks> Inbox<P> {
	pub fn origin(&self) -> &InboxOrigin {
		&self.origin
	}
	pub fn reference(&self) -> &Ref {
		&self.reference
	}
	pub(super) fn drained(&self) -> bool {
		*self.ended.borrow() && !self.live.active.get()
	}
	/// Drain the worker before closing its Host or session attachment. Any
	/// refused answer resolution remains visible to this lifecycle owner.
	pub async fn close(&mut self) -> Result<()> {
		self.live.closed.set(true);
		self.stop.send_replace(true);
		self.retire_publication()?;
		while !*self.ended.borrow_and_update() {
			self.ended
				.changed()
				.await
				.map_err(|_| loam::refusal("Session inbox worker ended without its close barrier"))?;
		}
		self.task.take();
		self.live.retire();
		match self.failure.borrow().as_ref() {
			Some(error) => Err(error.first.clone()),
			None => Ok(()),
		}
	}
	pub fn resolution_failures(&self) -> usize {
		self.failure.borrow().as_ref().map_or(0, |failure| failure.count)
	}
	pub fn refused_notices(&self) -> usize {
		self.live.refused.get()
	}
	pub(super) fn publish(&mut self, host: &Host, entropy: [u8; Host::DURABLE_ENTROPY_BYTES]) -> Result<()> {
		if self.publication.is_some() || self.live.closed.get() {
			return Err(loam::refusal("inbox publication is already owned or closed"));
		}
		let name = host.publish_reference_with_entropy(&self.reference, entropy)?;
		self.publication = Some((host.clone(), name));
		Ok(())
	}
	fn retire_publication(&mut self) -> Result<()> {
		if let Some((host, name)) = &self.publication {
			host.remove_durable(name)?;
			self.publication.take();
		}
		Ok(())
	}
}
impl<P: Tasks> Drop for Inbox<P> {
	fn drop(&mut self) {
		self.live.closed.set(true);
		self.stop.send_replace(true);
		if let Err(error) = self.retire_publication()
			&& let Some(writer) = self.live.budget.writer.upgrade()
		{
			writer.report("retire inbox publication", &error);
		}
		self.task.take();
	}
}

pub(super) fn open<P: Tasks + Deadline + Clone + 'static>(
	host: &Host,
	platform: P,
	workspace: Workspace<P>,
	selected: InboxSelection,
	budget: Rc<Budget>,
	receive: impl FnMut(&str, &[Argument], Option<glowcap::Session>, &InboxOrigin) -> std::result::Result<Argument, String>
	+ 'static,
) -> Result<Inbox<P>> {
	open_checked(
		host,
		platform,
		Admission::Install { workspace, selected },
		budget,
		receive,
	)
}

pub(super) fn open_discovery<P: Tasks + Deadline + Clone + 'static>(
	host: &Host,
	platform: P,
	workspace: Workspace<P>,
	selected: DiscoverySelection,
	budget: Rc<Budget>,
	synchronized: watch::Receiver<bool>,
	mut receive: impl FnMut(&[Argument], &InboxOrigin) -> std::result::Result<(), String> + 'static,
) -> Result<Inbox<P>> {
	open_checked(
		host,
		platform,
		Admission::Discovery {
			workspace,
			selected,
			synchronized,
		},
		budget,
		move |_, args, _, origin| receive(args, origin).map(|()| Argument::Void),
	)
}

pub(super) fn open_line<P: Tasks + Deadline + Clone + 'static>(
	host: &Host,
	platform: P,
	origin: InboxOrigin,
	budget: Rc<Budget>,
	mut behavior: glowcap::Behavior,
) -> Result<Inbox<P>> {
	let workspace = Workspace::local(host.clone(), platform.clone(), origin.source().clone());
	open_checked(
		host,
		platform,
		Admission::Child { workspace, origin },
		budget,
		move |verb, args, _, _| behavior(Some(verb), args),
	)
}

/// Where an inbox's origin comes from: a line inbox reuses its parent's, and
/// every other kind builds one from the selection it was admitted with.
enum OriginSource {
	Existing(InboxOrigin),
	Selected(Box<Selection>),
}
fn open_checked<P: Tasks + Deadline + Clone + 'static>(
	host: &Host,
	platform: P,
	admission: Admission<P>,
	budget: Rc<Budget>,
	mut receive: impl FnMut(
		&str,
		&[Argument],
		Option<glowcap::Session>,
		&InboxOrigin,
	) -> std::result::Result<Argument, String>
	+ 'static,
) -> Result<Inbox<P>> {
	let (workspace, origin, kind, synchronized) = match admission {
		Admission::Discovery {
			workspace,
			selected,
			synchronized,
		} => (
			workspace,
			OriginSource::Selected(Box::new(Selection::Discovery(selected))),
			Kind::Notification,
			Some(synchronized),
		),
		Admission::Install { workspace, selected } => {
			let kind = if matches!(selected, InboxSelection::Direct { .. }) {
				Kind::Direct
			} else {
				Kind::Notification
			};
			(
				workspace,
				OriginSource::Selected(Box::new(Selection::Installed(selected))),
				kind,
				None,
			)
		}
		Admission::Child { workspace, origin } => (workspace, OriginSource::Existing(origin), Kind::Line, None),
	};
	if budget.inboxes.get() == MAX_INBOXES {
		return Err(loam::refusal("Session callback owner capacity is exhausted"));
	}
	budget.inboxes.set(budget.inboxes.get() + 1);
	let live = Rc::new(Live {
		budget,
		closed: Cell::new(false),
		active: Cell::new(true),
		refused: Cell::new(0),
	});
	let weak = Rc::downgrade(&live);
	let (cleanup_sender, mut cleanups) = mpsc::channel::<Pending>(2);
	let (sender, mut requests) = mpsc::channel::<Pending>(QUEUED_PER_INBOX);
	let actor_host = host.clone();
	let receiving_clock = platform.clone();
	let mut remote = super::incoming::Sender::default();
	let reference = host.spawn(move |verb, args| {
		let verb = verb.ok_or("Unknown inbox method")?;
		let verb = if matches!(kind, Kind::Line) {
			use rooms_application::protocol_data as protocol;
			match verb {
				protocol::EDIT => protocol::EDIT,
				protocol::REFILE => protocol::REFILE,
				protocol::WITHDRAW => protocol::WITHDRAW,
				_ => return Err("Unknown direct line method".into()),
			}
		} else if matches!(kind, Kind::Direct) {
			use rooms_application::direct;
			match verb {
				direct::DM => direct::DM,
				direct::READY => direct::READY,
				direct::TYPING => direct::TYPING,
				direct::HAND_ROOM => direct::HAND_ROOM,
				direct::OFFER_ROOM => direct::OFFER_ROOM,
				direct::HAND_ARCHIVE => direct::HAND_ARCHIVE,
				direct::OFFER_ARCHIVE => direct::OFFER_ARCHIVE,
				_ => return Err("Unknown direct inbox method".into()),
			}
		} else if verb == rooms_application::protocol_data::NOTIFY {
			rooms_application::protocol_data::NOTIFY
		} else {
			return Err("Session inbox accepts only notify".into());
		};
		let live = weak.upgrade().ok_or("Session inbox owner has closed")?;
		if live.closed.get() {
			return Err("Session inbox owner has closed".into());
		}
		// Reserve both queue and aggregate custody before cloning arguments or
		// creating a deferred answer. Refusal leaves the original call intact.
		let cleanup = verb == rooms_application::protocol_data::WITHDRAW && args.is_empty();
		let selected = if cleanup { &cleanup_sender } else { &sender };
		let slot = selected
			.try_reserve()
			.map_err(|_| "Session inbox queue is unavailable")?;
		let bytes = demand(args)?;
		let charge = Charge::reserve(&live.budget.custody, bytes, cleanup)?;
		let delivering = if matches!(kind, Kind::Direct) {
			glowcap::current_session().map_err(|e| e.to_string())?
		} else {
			None
		};
		if matches!(kind, Kind::Direct | Kind::Line) {
			let sender = glowcap::current_session().map_err(|e| e.to_string())?;
			let key = remote.key(sender.as_ref())?;
			live.budget
				.admission
				.borrow_mut()
				.receive(key, verb, bytes, receiving_clock.monotonic_millis())?;
		}
		let args = args.to_vec();
		let resolver = actor_host.defer_turn_if_answer().map_err(|e| e.to_string())?;
		slot.send(Pending {
			verb,
			args,
			delivering,
			resolver,
			_charge: charge,
		});
		Ok(Argument::Void)
	})?;
	let (stop, mut stopping) = watch::channel(false);
	let (finished, ended) = watch::channel(false);
	let failure = Rc::new(RefCell::new(None));
	let failures = failure.clone();
	let receiving = live.clone();
	let origin = match origin {
		OriginSource::Existing(origin) => origin,
		OriginSource::Selected(selected) => InboxOrigin(Rc::new(Origin {
			source: workspace.reference().clone(),
			selected: *selected,
			installed: reference.clone(),
			live: Rc::downgrade(&live),
			recording: RefCell::new(None),
			next_route: Cell::new(1),
		})),
	};
	let retained_origin = origin.clone();
	let callback_platform = platform.clone();
	let task = platform.spawn(async move {
		// WATCH can emit notifications before its snapshot answer. Keep them in
		// the existing charged queue until the owner accepts initial state; then
		// perform fresh source admission for every queued notification.
		if let Some(mut synchronized) = synchronized {
			while !*synchronized.borrow_and_update() {
				let opened = tokio::select! {
					biased;
					_ = stopping.changed() => false,
					changed = synchronized.changed() => changed.is_ok(),
				};
				if !opened { break; }
			}
			if !*synchronized.borrow() { receiving.closed.set(true); }
		}
		loop {
			if receiving.closed.get() { break; }
			let mut request = tokio::select! {
				biased;
				_ = stopping.changed() => break,
				request = cleanups.recv() => match request { Some(request) => request, None => break },
				request = requests.recv() => match request { Some(request) => request, None => break },
			};
			// No projection, target lookup or separate authority cache intervenes
			// between the shared check and synchronous event delivery.
		let admission = tokio::select! {
				biased;
				_ = stopping.changed() => { resolve(&mut request, Err("Session inbox owner has closed".into()), &failures); break; },
				result = async {
					match &origin.0.selected {
						Selection::Installed(selected) => {
							let writer = receiving.budget.writer.upgrade().ok_or_else(|| loam::refusal("callback owner closed"))?;
							super::authority::retire(&writer, &workspace, selected,
								&origin.0.installed, request.verb, &request.args).await?;
							super::recording::admit(&writer, callback_platform.clone(), &workspace, selected, &origin.0.installed).await
						},
						Selection::Discovery(selected) => {
							let writer = receiving.budget.writer.upgrade().ok_or_else(|| loam::refusal("callback owner closed"))?;
							workspace.owner_check_discovery(&writer.root()?, selected).await.map(|()| None).map_err(|e| loam::refusal(e.to_string()))
						},
					}
				} => result,
			};
			let result = match admission {
				Ok(destination) if origin.is_open() => {
					*origin.0.recording.borrow_mut() = destination;
					let result = receive(request.verb, &request.args, request.delivering.take(), &origin);
					origin.0.recording.borrow_mut().take();
					result
				},
				Ok(_) => Err("Original callback owner has closed".into()),
				Err(error) => Err(error.to_string()),
			};
			if let Err(reason) = &result {
				receiving.refused.set(receiving.refused.get().saturating_add(1));
				if let Some(writer) = receiving.budget.writer.upgrade() {
					writer.report(request.verb, &loam::refusal(reason));
				}
			}
			resolve(&mut request, result, &failures);
		}
        cleanups.close();
        while let Some(mut request) = cleanups.recv().await {
            resolve(&mut request, Err("Session inbox owner has closed".into()), &failures);
        }
		requests.close();
		while let Some(mut request) = requests.recv().await {
			resolve(&mut request, Err("Session inbox owner has closed".into()), &failures);
		}
		finished.send_replace(true);
	});
	Ok(Inbox {
		task: Some(task),
		reference,
		live,
		stop,
		ended,
		failure,
		origin: retained_origin,
		publication: None,
	})
}

fn resolve(request: &mut Pending, result: std::result::Result<Argument, String>, failure: &RefCell<Option<Failure>>) {
	let Some(resolver) = request.resolver.as_mut() else {
		return;
	};
	let outcome = match result {
		Ok(value) => resolver.fulfill_value(&value),
		Err(reason) => resolver.break_with(&reason),
	};
	if let Err(error) = outcome {
		// Failed capability projection leaves the resolver live. Preserve its
		// real cause at both the caller and lifecycle owner before releasing it.
		let reason = error.to_string();
		let error = error.with_cleanup(resolver.break_with(&reason));
		let mut previous = failure.borrow_mut();
		if let Some(previous) = previous.as_mut() {
			previous.count = previous.count.saturating_add(1);
		} else {
			*previous = Some(Failure { first: error, count: 1 });
		}
	}
}
