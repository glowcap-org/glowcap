//! The CapTP object an attached view talks to. One `Facet` answers for the
//! administrator root and for every grant and minted delegate; what a caller
//! may do is read from its grant on every call, never captured at issue time.
use super::{
	answer,
	authority::Authority,
	error::Error,
	notice::Report,
	verbs,
	views::{Grantor, Views},
	Stop, Visualization,
};
use crate::archive_shares::ShareReceiver;
use crate::bridge_secrets::BridgeSecrets;
use crate::direct_commands::DirectCommands;
use crate::direct_dispatch::DirectDispatcher;
use crate::direct_events::EventReceiver;
use crate::direct_routes::DirectRoutes;
use crate::directory_runtime::handed_rooms::HandedReceiver;
use crate::directory_runtime::DirectoryRuntime;
use crate::grant_commands::GrantCommandEffects;
use crate::grant_commands::GrantNotice;
use crate::grant_publications::GrantedBehavior;
use crate::operations::Operations;
use crate::peering::Peering;
use crate::rooms::ConversationEvent;
use crate::rooms::RoomRuntime;
use crate::session_archive::SessionArchive;
use crate::session_commands::SessionCommands;
use crate::session_commands::SessionEvents;
use crate::session_service::Platform;
use crate::session_state::SessionView;
use glowcap::{Argument, Host};
use rooms_application::{
	grants::{protocol::GrantView, Access, Grant},
	room::ArgumentView,
	session::{
		checkpoint::{commands::Facts, reconciliation::Fact},
		state::Change,
		verbs as verb,
	},
	text::DocumentText,
};
use rooms_glowcap::Value;
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};

/// What one caller may do right now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rights {
	pub access: Access,
	/// Whether archived history and archived files may be read. Separate from
	/// `access` because a grant can interact without seeing the past.
	pub history: bool,
	/// Why the caller is suspended, when it is; shown in refusals and carried
	/// in the snapshot so a view learns of a pause it was not present for.
	pub note: DocumentText,
}

impl Rights {
	pub fn admin() -> Self {
		Self {
			access: Access::Admin,
			history: true,
			note: DocumentText::from(""),
		}
	}
	pub fn of(grant: &Grant) -> Self {
		Self {
			access: grant.access(),
			history: grant.history(),
			note: grant.note().clone(),
		}
	}
	pub fn may_observe(&self) -> bool {
		self.access != Access::None
	}
	pub fn may_interact(&self) -> bool {
		matches!(self.access, Access::Interact | Access::Admin)
	}
	pub fn is_admin(&self) -> bool {
		self.access == Access::Admin
	}
}

/// Everything a facet answers with. Named fields, because a positional list
/// this long is where two `Rc<...>` clones get swapped without a type error.
pub struct Parts<P: Platform> {
	pub platform: P,
	pub viz: Rc<dyn Visualization>,
	pub entropy: Box<dyn crate::entropy::Entropy>,
	pub host: Host,
	pub commands: SessionCommands,
	pub bridge_secrets: BridgeSecrets,
	pub directories: DirectoryRuntime<P>,
	pub rooms: RoomRuntime<P>,
	pub routes: DirectRoutes<P>,
	pub dispatcher: DirectDispatcher<P>,
	pub directs: DirectCommands,
	pub archive: Rc<SessionArchive<P>>,
	pub events: EventReceiver<P>,
	pub handed: HandedReceiver<P>,
	pub shares: ShareReceiver,
	pub member_locator: String,
	pub report: Report,
}

pub(super) struct Inner<P: Platform> {
	pub answers: answer::Answers,
	pub local_views: super::local::observation::Observers,
	pub local_file_reads: Rc<Cell<u32>>,
	pub grant_commands: std::cell::OnceCell<crate::grant_commands::GrantCommands>,
	pub platform: P,
	pub entropy: RefCell<Box<dyn crate::entropy::Entropy>>,
	pub host: Host,
	pub commands: SessionCommands,
	pub bridge_secrets: BridgeSecrets,
	pub directories: DirectoryRuntime<P>,
	pub rooms: RoomRuntime<P>,
	pub routes: DirectRoutes<P>,
	pub dispatcher: DirectDispatcher<P>,
	pub directs: DirectCommands,
	pub archive: Rc<SessionArchive<P>>,
	pub events: EventReceiver<P>,
	pub handed: HandedReceiver<P>,
	pub shares: ShareReceiver,
	pub operations: Operations<P>,
	pub viz: Rc<dyn Visualization>,
	pub peering: Peering<P>,
	/// Live archived-file readers per attached connection; owned behavior
	/// retirement returns capacity without waiting for reconnection.
	pub attachment_reads: RefCell<Vec<(glowcap::Session, Rc<Cell<u32>>)>>,
	pub report: Report,
	pub member_locator: String,
	grants: RefCell<Vec<GrantView>>,
	views: RefCell<Views>,
	/// Minted delegates are numbered here so a revocation names exactly one.
	next_delegate: Cell<u64>,
	live: Cell<bool>,
}

#[derive(Clone)]
pub struct Facet<P: Platform>(pub(super) Rc<Inner<P>>);

impl<P: Platform> Facet<P> {
	pub fn new(parts: Parts<P>) -> Self {
		Self(Rc::new(Inner::<P> {
			host: parts.host,
			commands: parts.commands,
			bridge_secrets: parts.bridge_secrets,
			directories: parts.directories,
			rooms: parts.rooms,
			routes: parts.routes,
			dispatcher: parts.dispatcher,
			directs: parts.directs,
			archive: parts.archive,
			events: parts.events,
			handed: parts.handed,
			shares: parts.shares,
			operations: Operations::new(parts.platform.clone()),
			viz: parts.viz,
			entropy: RefCell::new(parts.entropy),
			peering: Peering::new(parts.platform.clone()),
			platform: parts.platform,
			answers: answer::Answers::new(),
			local_views: Default::default(),
			local_file_reads: Rc::default(),
			grant_commands: Default::default(),
			attachment_reads: RefCell::new(Vec::new()),
			report: parts.report.clone(),
			member_locator: parts.member_locator,
			grants: RefCell::new(Vec::new()),
			views: RefCell::new(Views::new(parts.report)),
			next_delegate: Cell::new(0),
			live: Cell::new(true),
		}))
	}
	pub(super) fn require_live(&self) -> Result<(), Error> {
		if self.0.live.get() {
			Ok(())
		} else {
			Err(Error::refused("this Rooms session facet was revoked"))
		}
	}
	pub fn routes(&self) -> &DirectRoutes<P> {
		&self.0.routes
	}
	pub fn load_grants(&self, views: Vec<GrantView>) {
		*self.0.grants.borrow_mut() = views;
	}
	pub(super) fn views(&self) -> std::cell::RefMut<'_, Views> {
		self.0.views.borrow_mut()
	}
	pub(super) fn next_delegate(&self) -> u64 {
		let id = self.0.next_delegate.get();
		self.0.next_delegate.set(id + 1);
		id
	}
	/// Keep the retained operations, viz, and peering credentials matched to the
	/// checkpoint. Runs until `stop`.
	pub fn reconciliation(&self, mut stop: Stop) -> impl std::future::Future<Output = Result<(), Error>> + 'static {
		let facet = self.clone();
		let notify: Rc<dyn Fn(&str)> = Rc::new({
			let facet = Rc::downgrade(&facet.0);
			move |scope: &str| {
				if let Some(facet) = facet.upgrade() {
					let facet = Facet(facet);
					facet.views().operations_changed(scope);
					facet
						.0
						.local_views
						.deliver(&facet.0.report, |view| view.operations_changed(scope));
					facet.notify();
				}
			}
		});
		facet.0.operations.on_invalidated(notify.clone());
		facet.0.viz.on_invalidated(notify.clone());
		facet.0.peering.on_invalidated(notify);
		let mut directories = self.0.directories.changes();
		let mut rooms = self.0.rooms.changes();
		let mut ops = self.0.operations.changes();
		let mut viz = self.0.viz.changes();
		let mut peering = self.0.peering.changes();
		async move {
			loop {
				if *stop.borrow() || !facet.0.live.get() {
					break Ok(());
				}
				facet.reconcile_authority().await;
				tokio::select! {
					_ = stop.changed() => break Ok(()),
					result = directories.changed() => if result.is_err() { break Ok(()) },
					result = rooms.changed() => if result.is_err() { break Ok(()) },
					result = ops.changed() => if result.is_err() { break Ok(()) },
					result = viz.changed() => if result.is_err() { break Ok(()) },
					result = peering.changed() => if result.is_err() { break Ok(()) },
				}
			}
		}
	}
	pub(super) async fn reconcile_authority(&self) {
		if !self.0.live.get() {
			return;
		}
		self.0.operations.reconcile(&self.0.commands, &self.0.directories).await;
		if !self.0.live.get() {
			return;
		}
		self.0.viz.reconcile(&self.0.commands);
		self.0
			.peering
			.reconcile(&self.0.commands, &self.0.directories, &self.0.rooms)
			.await;
	}
	/// Something an attached view's snapshot depends on changed. Views are told
	/// once per tick, however many owners changed in it.
	pub fn notify(&self) {
		self.0.local_views.deliver(&self.0.report, |view| view.changed());
		Views::schedule_snapshots(self);
	}
	/// A durable boundary committed. Its snapshot is queued now, before the
	/// reply to the command that committed it can be, so a view never holds a
	/// snapshot older than an answer it has already received.
	pub fn notify_now(&self) {
		self.0.local_views.deliver(&self.0.report, |view| view.changed());
		super::views::flush_snapshots(self);
	}
	pub fn deliver_event(&self, event: &ConversationEvent) {
		self.deliver_event_except(event, None);
	}
	/// Deliver to every view but the one attached over `except`. An event with
	/// attachments is acknowledged by each view; the facet waits for that
	/// answer before its proxies may drop, and retires a view that refuses.
	pub(super) fn deliver_event_except(&self, event: &ConversationEvent, except: Option<&glowcap::Session>) {
		self.deliver_event_excluding(event, except, None);
	}
	pub(super) fn deliver_event_excluding(
		&self,
		event: &ConversationEvent,
		except: Option<&glowcap::Session>,
		local: Option<u64>,
	) {
		self.0
			.local_views
			.deliver_except(&self.0.report, local, |view| view.event(event));
		for acknowledgement in self.views().event_except(event, except, &self.0.answers) {
			let weak = Rc::downgrade(&self.0);
			let view = acknowledgement.view;
			if let Err(cause) = self.0.answers.spawn(async move {
				let outcome = acknowledgement.reply.await;
				drop(acknowledgement.proxies);
				if let Err(cause) = outcome {
					if let Some(inner) = weak.upgrade() {
						let facet = Facet(inner);
						facet.views().remove(acknowledgement.view);
						(facet.0.report)(super::notice::Notice::ViewRetired { cause: cause.into() });
					}
				}
			}) {
				self.views().remove(view);
				(self.0.report)(super::notice::Notice::ViewRetired { cause });
			}
		}
	}
	/// Stop answering and drop every attached view. Owners the facet names
	/// are closed by the peer afterwards.
	pub fn stop(&self) {
		self.0.live.set(false);
		self.0.local_views.close();
		self.0.answers.stop();
		self.0.viz.stop();
		self.views().clear();
	}
	pub async fn close(&self) -> Result<(), Error> {
		self.stop();
		self.0.answers.close().await;
		self.0.viz.close().await
	}
	/// The behavior every published grant facet runs, reading its rights from
	/// the grant on each call.
	pub fn granted_behavior(&self) -> GrantedBehavior {
		let facet = self.clone();
		Box::new(move |authority, grant, verb, args| {
			facet.invoke(
				&Authority::Published(authority.clone()),
				&Grantor::Grant(grant.id().to_owned()),
				verb,
				args,
			)
		})
	}
	/// The administrator root's own methods.
	pub fn invoke_admin(&self, verb: &str, args: &[Argument]) -> Result<Argument, String> {
		self.invoke(&Authority::Admin, &Grantor::Admin, verb, args)
	}
	/// The CapTP boundary: the one place a typed failure becomes a break reason.
	pub(super) fn invoke(
		&self,
		authority: &Authority,
		grantor: &Grantor,
		verb: &str,
		args: &[Argument],
	) -> Result<Argument, String> {
		authority
			.rights()
			.and_then(|rights| self.dispatch(&rights, authority, grantor, verb, args))
			.map_err(|error| error.to_string())
	}
	fn dispatch(
		&self,
		rights: &Rights,
		authority: &Authority,
		grantor: &Grantor,
		verb: &str,
		args: &[Argument],
	) -> Result<Argument, Error> {
		if !self.0.live.get() {
			return Err(Error::refused("this Rooms session facet was revoked"));
		}
		if !matches!(verb, verb::WATCH | verb::SEND_FILES | verb::REFILE_LINE)
			&& args
				.iter()
				.any(|value| ArgumentView::contains_capability(&Value(value)))
		{
			return Err(Error::refused(format!("{verb} does not take capability arguments")));
		}
		if verb == verb::SNAPSHOT {
			if !args.is_empty() {
				return Err(Error::refused("session snapshot takes no arguments"));
			}
			return self.snapshot(rights);
		}
		// A suspended link still answers for itself and may keep watching, so
		// a view already attached learns the moment the suspension lifts.
		// Every other verb is refused here, once, rather than in each handler.
		if !rights.may_observe() && verb != verb::WATCH {
			return Err(Error::refused(suspended(&rights.note)));
		}
		match verb {
			verb::WATCH => verbs::views::watch(self, rights, grantor, args),
			verb::ADOPT_WORKSPACE | verb::REPLACE_CHECKPOINT => verbs::checkpoint::request(self, rights, verb, args),
			verb::COMMAND => verbs::command::dispatch(self, rights, args),
			verb::TYPING => verbs::typing::typing(self, rights, args),
			verb::READ_HISTORY | verb::READ_HISTORY_VIEW => verbs::history::read(self, authority, verb, args),
			verb::SEND_FILES => verbs::files::send(self, rights, args),
			verb::REFILE_LINE => verbs::files::refile(self, rights, args),
			verb::ROOM_BRIDGE_FORM => verbs::bridge::form(self, args),
			verb::RESOLVE_EFFECT | verb::RESUME_EFFECT => verbs::results::external(self, rights, verb, args),
			verb::FACET => verbs::delegation::mint(self, rights, args),
			verb::OPERATOR_SNAPSHOT | verb::OPERATOR_PAGE | verb::OPERATOR_RETIRE => {
				verbs::operator::inspect(self, rights, verb, args)
			}
			verb::OPERATIONS_SNAPSHOT => verbs::operations::snapshot(self, rights, args),
			verb::SHARE_ARCHIVE
			| verb::OFFER_DURABLE_ARCHIVE
			| verb::READ_ARCHIVE_SHARE
			| verb::DROP_ARCHIVE_SHARE
			| verb::LIST_ARCHIVE_SHARES
			| verb::REVOKE_ARCHIVE_SHARE => verbs::archive_shares::dispatch(self, rights, verb, args),
			verb::ARCHIVED_ATTACHMENT => verbs::attachments::archived(self, authority, args),
			_ => Err(Error::refused(format!("Rooms session facet has no method {verb}"))),
		}
	}
	pub(super) fn local_snapshot(&self) -> Result<rooms_application::session::snapshot::Snapshot, Error> {
		self.require_live()?;
		let mut snapshot = crate::session_projection::current(
			&self.0.commands.view(),
			&self.0.member_locator,
			&self.0.directories.read(),
			&self.0.rooms,
			&self.0.grants.borrow(),
			&self.0.handed.read(super::snapshot::handed),
			&self.0.shares.views(),
		)?;
		let mut issues = snapshot.issues.as_slice().to_vec();
		if let Some(reason) = self.0.archive.selection_issue() {
			issues.push(super::snapshot::attachment_issue("archive", &reason)?);
		}
		for (subject, reason) in self.0.events.recording_issues() {
			issues.push(super::snapshot::attachment_issue(&subject, &reason)?);
		}
		for (subject, reason) in self.0.operations.issues() {
			issues.push(super::snapshot::attachment_issue(&subject, &reason)?);
		}
		snapshot.issues = rooms_application::session::snapshot::List::new(issues)
			.ok_or_else(|| Error::runtime("session issues exceed the snapshot bound"))?;
		Ok(snapshot)
	}
	pub(super) fn snapshot(&self, rights: &Rights) -> Result<Argument, Error> {
		Ok(Argument::List(self.encode_snapshot(rights, &[])?))
	}
	/// The snapshot one caller sees, with any issues that belong to that
	/// attachment alone beside the session's own.
	pub(super) fn encode_snapshot(
		&self,
		rights: &Rights,
		extra_issues: &[(
			rooms_application::session::snapshot::Field,
			rooms_application::session::snapshot::Field,
		)],
	) -> Result<Vec<Argument>, Error> {
		let grants = self.0.grants.borrow();
		let handed = self.0.handed.read(super::snapshot::handed);
		let shares = self.0.shares.views();
		let mut issues = extra_issues.to_vec();
		if let Some(reason) = self.0.archive.selection_issue() {
			issues.push(super::snapshot::attachment_issue("archive", &reason)?);
		}
		for (subject, reason) in self.0.events.recording_issues() {
			issues.push(super::snapshot::attachment_issue(&subject, &reason)?);
		}
		if rights.is_admin() {
			for (subject, reason) in self.0.operations.issues() {
				issues.push(super::snapshot::attachment_issue(&subject, &reason)?);
			}
		}
		super::snapshot::encode(
			&self.0.commands.view(),
			&self.0.member_locator,
			&self.0.directories.read(),
			&self.0.rooms,
			&grants,
			&handed,
			&shares,
			rights.access,
			&rights.note,
			&issues,
		)
	}
	/// Tell each view whose grant was revoked once more, naming the
	/// revocation, before the peer forgets it. The snapshot carries the rights
	/// the view last held, so it can still show what it is losing.
	fn tell_revoked(&self, retired: Vec<super::views::Retired>) {
		const REVOKED: &str = "This session capability was revoked. Detach it or attach with another capability.";
		for view in retired {
			let told = super::snapshot::attachment_issue("session-access", REVOKED)
				.and_then(|issue| self.encode_snapshot(&view.rights, &[issue]))
				.and_then(|args| {
					Ok(view
						.session
						.tell(&view.observer, rooms_application::session::CHANGED, &args)?)
				});
			if let Err(cause) = told {
				(self.0.report)(super::notice::Notice::ViewRetired { cause });
			}
		}
	}
	/// Answer later, from a future that runs outside this turn.
	pub(super) fn answer<F>(&self, verb: &'static str, work: F) -> Result<Argument, Error>
	where
		F: std::future::Future<Output = Result<Argument, Error>> + 'static,
	{
		self.0.answers.later(self.0.report.clone(), verb, work)
	}
}

impl<P: Platform> SessionEvents for Facet<P> {
	async fn preparing(
		&mut self,
		_checkpoint: &rooms_application::session::checkpoint::Checkpoint,
	) -> Result<impl Sized + 'static, String> {
		Ok(())
	}

	fn facts(&self) -> impl Facts + '_ {}
	fn changed(&mut self, _: Change, _: &SessionView) {
		self.0.operations.kick();
		self.0.viz.kick();
		self.0.peering.kick();
		self.notify_now();
	}
	fn reconciliation_issue(&mut self, _: &Fact, _: Option<&str>) {
		self.notify_now();
	}
}

impl<P: Platform> GrantCommandEffects for Facet<P> {
	fn local_reply_failed(&mut self, error: String) {
		(self.0.report)(super::notice::Notice::AnswerUndeliverable {
			verb: "grant-command",
			cause: Error::runtime(error),
		});
	}
	fn reply_failed(&mut self, error: glowcap::Error) {
		(self.0.report)(super::notice::Notice::GrantReplyFailed(error));
	}
	fn changed<D: crate::documents::Document>(
		&mut self,
		notice: GrantNotice<'_>,
		grants: &crate::grant_publications::PublishedGrants<D>,
	) -> impl core::future::Future<Output = Result<(), String>> {
		let outcome = match notice {
			GrantNotice::Unavailable => {
				self.0.grants.borrow_mut().clear();
				self.views().retire_granted();
				Ok(())
			}
			GrantNotice::Committed { .. } | GrantNotice::Routed => match self
				.0
				.grant_commands
				.get()
				.ok_or_else(|| "Rooms grant owner is not ready".to_owned())
				.and_then(|owner| owner.views(grants))
			{
				Ok(views) => {
					*self.0.grants.borrow_mut() = views;
					// A narrowing is worth having only if it reaches the views
					// already holding the link: re-read every granted view's
					// rights from the ledger it was issued from.
					let retired = self.views().retier(|id| {
						grants.grants().ok().and_then(|ledger| {
							ledger
								.get(id)
								.ok()
								.flatten()
								.filter(|grant| !grant.revoked())
								.map(Rights::of)
						})
					});
					self.tell_revoked(retired);
					Ok(())
				}
				Err(error) => Err(error),
			},
		};
		self.notify_now();
		async move { outcome }
	}
}

fn suspended(note: &DocumentText) -> String {
	match note.as_str().filter(|text| !text.is_empty()) {
		Some(text) => format!("this Rooms session capability is suspended: {text}"),
		None => "this Rooms session capability is suspended".into(),
	}
}
