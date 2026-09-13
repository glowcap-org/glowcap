//! The one owner every connection's verbs share: the policies, the live
//! sessions by connection id, the clock the policies' windows are measured
//! on, the listener seats, the trouble journal, and the queue of work that
//! must run outside a turn. Applying a policy's effects is the only place a
//! capability is told, given back, or rejected, so every verb performs
//! effects the same way.
use super::{
	notice::{Notice, Report},
	operations::listeners::Registry,
};
use glowcap::{Argument, Host, Locator, Ref, Resolver, Session};
use rooms_application::{
	directory::{Shape, registration::Id, wire},
	room::{inbox::NOTIFY, stewardship::Kind},
	server::{
		directory::{Directory, Dropped, Effects, Notice as MemberNotice, Route, Tell},
		history::Persist,
		links::Authority,
		operations::{journal::Journal, operator::revision::Revision},
		peering::Foreign,
		rooms::{self, Rooms},
	},
};
use rooms_glowcap::snapshot::Arguments;
use std::{cell::RefCell, collections::BTreeMap, future::Future, pin::Pin, rc::Rc};
use tokio::{sync::mpsc, time::Instant};

pub(super) type Policy = Directory<u64, Ref>;
pub(super) type Shared = Rc<RefCell<State>>;

/// Work the serving loop runs on the policies' behalf, outside any turn.
/// The channel is bounded by `WORK_LIMIT`; a verb whose work cannot be
/// queued is refused, so a flood parks at the caller rather than in memory.
pub(super) enum Work {
	/// Deliver an offer to its target's signaling inbox; once the target has
	/// taken it, tell the originator `accepted`.
	Offer {
		id: String,
		target: Route<u64, Ref>,
		sdp: String,
		originator: u64,
		reply: Ref,
	},
	/// Ask a member for an inbox, then break the caller's deferred answer
	/// with `pending` once the member has taken the request, or `offline`
	/// when it could not be reached.
	Introduce {
		target: Tell<u64, Ref>,
		caller: Session,
		resolver: Resolver,
		pending: String,
		offline: String,
	},
	/// A deferred answer that waits on something the loop owns: a blob's
	/// bytes, a link's persistence.
	Task(Pin<Box<dyn Future<Output = ()>>>),
}

/// Work queued but not yet started.
pub(super) const WORK_LIMIT: usize = 256;

/// One accepted connection: its session view, the durable identity it
/// proved, if any, by which two connections are one peer, and the id an
/// operator names it by.
struct Connection {
	session: Session,
	claimant: Option<String>,
	operator_id: String,
	/// The room presence last stated on the live trace for this session:
	/// the nick of its membership, or none. Stated again only when it
	/// changes, so a line said in a room is not a fresh claim.
	presence: RefCell<Option<String>>,
}

/// One accepted session as an operator inventory reads it.
pub(super) struct SessionFace {
	pub id: String,
	pub transport: String,
	pub nick: String,
	pub connection: u64,
}

pub(super) struct State {
	pub policy: Policy,
	pub rooms: Rooms<u64, Ref>,
	pub irc: super::irc::Runtime,
	/// The durable authority as last installed; the loop's authority worker
	/// is the one writer.
	pub authority: Authority,
	pub authority_writer: super::authority::queue::Handle,
	/// The durable names published for that authority.
	pub links: super::authority::Links,
	pub listeners: Registry,
	pub operations: super::operations::document::Handle,
	/// The boot listener, for re-selecting the announced location after a
	/// runtime listener took the selection.
	pub boot_listener: Option<Rc<rooms_platform::serving::Listener>>,
	/// Failures that had no caller left to answer, for an operator to read.
	/// A cell, because every report writes it and reports come from shared
	/// borrows.
	pub journal: RefCell<Journal>,
	/// The operator's revision and watchers, moved by every change an
	/// inventory reads; a cell for the same reason as the journal.
	pub operator: RefCell<Revision<u64, Ref>>,
	/// Rooms other directories publish here.
	pub foreign: Foreign<u64, Ref>,
	/// What each pending publication's lease waits on, by publication id.
	pub peering_ready: BTreeMap<String, tokio::sync::watch::Sender<super::operations::peering::Outcome>>,
	connections: BTreeMap<u64, Connection>,
	next: u64,
	start: Instant,
	/// Admission may create the first upload deadline while the serving loop
	/// sleeps. Coalesced notifications make it reconsider that deadline.
	pub upload_admitted: Rc<tokio::sync::Notify>,
	/// The work queue. A verb reserves its seat here before it commits
	/// anything that depends on the work happening.
	pub work: mpsc::Sender<Work>,
	/// Where kept lines go to be persisted, when the server keeps any.
	pub history: Option<mpsc::Sender<Persist>>,
	report: Report,
	pub host: Host,
	pub locator: Locator,
	/// What `advertisedLocation` answers a caller without a route: the boot
	/// listener's own locator.
	pub location: String,
	shared: std::rc::Weak<RefCell<State>>,
}

impl State {
	/// Live, durable and in-flight host names share the same exclusion
	/// boundary for foreign and IRC publication.
	pub fn rooms_name_taken(&self, name: &str) -> bool {
		self.rooms.public_name_taken(name)
			|| self.authority.public_name_taken(name)
			|| self.authority_writer.holds_name(name)
	}
	#[allow(clippy::too_many_arguments)]
	pub fn new(
		host: Host,
		authority: Authority,
		authority_writer: super::authority::queue::Handle,
		rooms: Rooms<u64, Ref>,
		listeners: Registry,
		operations: super::operations::document::Handle,
		work: mpsc::Sender<Work>,
		history: Option<mpsc::Sender<Persist>>,
		report: Report,
	) -> Self {
		Self {
			policy: Policy::default(),
			rooms,
			irc: Default::default(),
			authority,
			authority_writer,
			links: Default::default(),
			listeners,
			operations,
			boot_listener: None,
			journal: RefCell::new(Journal::default()),
			operator: RefCell::new(Revision::default()),
			foreign: Foreign::default(),
			peering_ready: BTreeMap::new(),
			connections: BTreeMap::new(),
			next: 0,
			start: Instant::now(),
			upload_admitted: Rc::new(tokio::sync::Notify::new()),
			work,
			history,
			report,
			host,
			locator: glowcap::tcp::locator("127.0.0.1", 0),
			location: String::new(),
			shared: std::rc::Weak::new(),
		}
	}
	/// The boot listener opened: this is the locator the server announces. A
	/// locator that cannot be written as a URI is refused rather than announced
	/// as an empty location.
	pub fn set_location(&mut self, locator: Locator) -> Result<(), glowcap::Error> {
		self.location = glowcap::format_locator_uri(&locator)?;
		self.locator = locator;
		Ok(())
	}
	/// Milliseconds since the peer started: the clock the policies' windows
	/// are measured on.
	pub fn now(&self) -> u64 {
		u64::try_from(self.start.elapsed().as_millis()).unwrap_or(u64::MAX)
	}
	/// When `at`, a value of `now`, falls on the loop's clock.
	pub fn instant(&self, at: u64) -> Instant {
		self.start + std::time::Duration::from_millis(at)
	}
	/// Milliseconds since the Unix epoch, the timestamp kept lines carry.
	pub fn wall_clock() -> u64 {
		std::time::SystemTime::now()
			.duration_since(std::time::UNIX_EPOCH)
			.map(|since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX))
			.unwrap_or(0)
	}
	/// File a session once, whether its first turn or the accept loop arrives
	/// first. Both paths must share the same policy owner and cleanup.
	pub fn admit(&mut self, session: Session) -> u64 {
		if let Some(id) = self.connection_of(&session) {
			return id;
		}
		let id = self.next;
		self.next += 1;
		let claimant = session
			.partner_identity()
			.ok()
			.filter(|identity| identity.durable_identity_authenticated() && !identity.designator.is_empty())
			.map(|identity| identity.designator);
		let mut entropy = [0u8; 16];
		if let Err(cause) = rooms_platform::entropy::fill(&mut entropy) {
			// A connection id an operator can still act on; the failure is
			// theirs to read.
			self.report(Notice::Trouble {
				source: "minting a session id".into(),
				reason: cause.to_string(),
			});
			entropy[8..].copy_from_slice(&id.to_be_bytes());
		}
		self.connections.insert(
			id,
			Connection {
				session,
				claimant,
				operator_id: Id::from_entropy(entropy).as_str().into(),
				presence: RefCell::new(None),
			},
		);
		self.changed();
		id
	}
	pub fn session(&self, connection: u64) -> Option<&Session> {
		self.connections.get(&connection).map(|held| &held.session)
	}
	/// The connection `session` is served over. A room reference crosses
	/// connections, so the calling session names the caller, not the session
	/// the reference was minted on.
	pub fn connection_of(&self, session: &Session) -> Option<u64> {
		self.connections
			.iter()
			.find(|(_, held)| held.session.same_session(session))
			.map(|(id, _)| *id)
	}
	/// The connection an operator id names.
	pub fn connection_by_operator_id(&self, id: &str) -> Option<u64> {
		self.connections
			.iter()
			.find(|(_, held)| held.operator_id == id)
			.map(|(connection, _)| *connection)
	}
	/// The proved peer of every connection, for a policy call that must
	/// compare claims while this owner is already borrowed.
	pub fn claimants(&self) -> BTreeMap<u64, Option<String>> {
		self.connections
			.iter()
			.map(|(id, held)| (*id, held.claimant.clone()))
			.collect()
	}
	/// Every accepted session as the inventories read it: a closing session
	/// says so in place of its transport.
	pub fn session_faces(&self) -> impl Iterator<Item = SessionFace> + '_ {
		self.connections.iter().map(|(connection, held)| SessionFace {
			id: held.operator_id.clone(),
			transport: if held.session.is_open() {
				held.session.transport_name().unwrap_or_else(|_| "closing".into())
			} else {
				"closing".into()
			},
			nick: self.policy.registered_nick(*connection).unwrap_or("").into(),
			connection: *connection,
		})
	}
	/// The connection ended: both policies withdraw everything it held, and
	/// the effects go to the connections still here.
	pub fn closed(&mut self, connection: u64) {
		if !self.connections.contains_key(&connection) {
			return;
		}
		super::irc::departed(self, connection);
		let effects = self.policy.connection_closed(connection);
		let rooms = self.rooms.connection_closed(connection);
		self.forget_foreign_from(connection);
		self.connections.remove(&connection);
		if let Some(observer) = self.operator.borrow_mut().unwatch(connection) {
			drop(observer);
		}
		self.apply(effects);
		self.apply_rooms(rooms);
	}
	/// Every room the directory lists: its own and the foreign ones.
	pub fn listed(&self) -> impl Iterator<Item = rooms_application::directory::RoomInfo> + '_ {
		self.rooms
			.listed()
			.chain(self.foreign.listed())
			.chain(self.irc.core.borrow().listed().collect::<Vec<_>>())
	}
	/// Report a failure with no caller left to answer: the operator hears
	/// it, and the journal keeps it for the inventories.
	pub fn report(&self, notice: Notice) {
		self.journal.borrow_mut().note(notice.source(), &notice.reason());
		(self.report)(notice);
		self.changed();
	}
	/// Something an operator inventory reads changed: the revision moves,
	/// and every watcher hears it unless a hold is coalescing the word.
	pub fn changed(&self) {
		let announce = self.operator.borrow_mut().note();
		if let Some(announce) = announce {
			self.announce_revision(announce.0);
		}
	}
	pub fn announce_revision(&self, revision: u64) {
		let watchers: Vec<(u64, Ref)> = self
			.operator
			.borrow()
			.watchers()
			.map(|(connection, observer)| (connection, observer.clone()))
			.collect();
		for (connection, observer) in watchers {
			let Some(held) = self.connections.get(&connection) else {
				continue;
			};
			// tolerant: a watcher whose word cannot be queued is withdrawn
			// when its connection ends; reporting it here would move the
			// revision again and announce again, without end.
			let _ = held
				.session
				.tell(&observer, "changed", &[Argument::Integer(revision as i64)]);
		}
	}
	pub fn reporter(&self) -> Report {
		self.report.clone()
	}
	/// The shared handle actors capture, once the owner is shared.
	pub fn shared(&self) -> Shared {
		self.shared
			.upgrade()
			.expect("the state is shared for as long as any actor can call it")
	}
	pub fn share(shared: &Shared) {
		shared.borrow_mut().shared = Rc::downgrade(shared);
	}
	/// A seat in the work queue. `None` means the queue is full.
	pub fn reserve(&self) -> Option<mpsc::Permit<'_, Work>> {
		self.work.try_reserve().ok()
	}
	/// The location a caller is advertised: the identity route across every
	/// listener when the caller negotiated the route vocabulary, else the
	/// listener its own connection came in through, else the announced one.
	pub fn advertised_locator(&self, caller: Option<&Session>) -> Locator {
		let Some(caller) = caller else {
			return self.locator.clone();
		};
		let profile = caller.profile().ok();
		let routes_spoken = profile.as_ref().is_some_and(|profile| {
			profile.captp_version == glowcap::CaptpVersion::Next
				&& profile.features.contains(glowcap::FeatureSet::MULTI_LOCATION)
		});
		if routes_spoken {
			let locators: Vec<String> = self
				.listeners
				.locators()
				.into_iter()
				.map(|(_, locator)| locator)
				.collect();
			if let Some(route) = self
				.host
				.designator()
				.ok()
				.and_then(|key| rooms_glowcap::routes::identity_route(&key, &locators))
			{
				return route;
			}
		}
		let transport = caller.transport_name().ok();
		let announced = self.listeners.seats.announced();
		self.listeners
			.locators()
			.into_iter()
			.find(|(held, _)| Some(held.name()) == transport.as_deref())
			// The announced seat answers the complete locator the server
			// printed, profile hints and all; a runtime seat its own locator.
			.filter(|(_, locator)| locator != announced)
			.and_then(|(_, locator)| rooms_glowcap::routes::locator(&locator))
			.unwrap_or_else(|| self.locator.clone())
	}
	/// The sturdyref a durable name answers to at this server, for the
	/// session whose turn is running, or at the announced listener.
	pub fn link(&self, swiss: &str) -> Result<String, String> {
		let caller = glowcap::current_session().ok().flatten();
		self.link_for(swiss, caller.as_ref())
	}
	/// A durable reply uses its retained caller after the originating turn ends.
	pub fn link_for(&self, swiss: &str, caller: Option<&Session>) -> Result<String, String> {
		let locator = self.advertised_locator(caller);
		glowcap::format_sturdyref(&locator, swiss.as_bytes(), glowcap::CaptpVersion::V1_0).map_err(|e| e.to_string())
	}
	/// The steward sturdyref for `name`, when one is published.
	pub fn steward_link(&self, name: &str) -> Option<String> {
		let caller = glowcap::current_session().ok().flatten();
		self.steward_link_for(name, caller.as_ref())
	}
	pub fn steward_link_for(&self, name: &str, caller: Option<&Session>) -> Option<String> {
		let swiss = self.links.swiss(Kind::Steward, name)?;
		self.link_for(swiss, caller).ok()
	}
	/// Perform everything one directory verb asked for: notices first,
	/// then what goes back, the same order the room effects keep.
	pub fn apply(&self, effects: Effects<u64, Ref>) {
		for tell in effects.tells {
			self.tell_member(&tell);
		}
		self.announce(&effects.events);
		for dropped in effects.dropped {
			self.reject(dropped);
		}
		for release in effects.releases {
			self.give_back(release.connection, release.capability);
		}
		self.changed();
	}
	/// Perform everything one room verb asked for. Notices go before
	/// capabilities are given back: a member asked to leave hears the room's
	/// word on the inbox that goes back a moment later.
	pub fn apply_rooms(&self, effects: rooms::Effects<u64, Ref>) {
		for tell in effects.tells {
			let Some(session) = self.connections.get(&tell.connection) else {
				continue;
			};
			let mut encoder = super::files::Minter {
				state: self,
				session: &session.session,
			};
			match rooms::wire::arguments(&tell.notice, &mut encoder) {
				Ok(args) => {
					self.tell(tell.connection, &tell.inbox, NOTIFY, &args);
				}
				Err(cause) => self.report(Notice::Undelivered { verb: NOTIFY, cause }),
			}
		}
		self.announce(&effects.events);
		for release in effects.releases {
			self.give_back(release.connection, release.capability);
		}
		for connection in effects.presence {
			self.state_presence(connection);
		}
		self.changed();
	}
	/// State this connection's room presence on the live trace, or withdraw
	/// the claim when it holds none. A claim, not identity: a viewer only
	/// displays it, and stating it here means a member joining, changing
	/// rooms, or leaving is one visible change in the picture rather than a
	/// name frozen at whatever was said first.
	pub(super) fn state_presence(&self, connection: u64) {
		let Some(held) = self.connections.get(&connection) else {
			return;
		};
		let nick = self
			.rooms
			.live()
			.flat_map(|room| room.members)
			.find(|member| member.connection == connection)
			.map(|member| member.nick.to_owned())
			.or_else(|| {
				self.irc
					.core
					.borrow()
					.bridges()
					.filter(|(_, bridge)| !bridge.stopped)
					.find_map(|(_, bridge)| bridge.room.member_nick(connection).map(String::from))
			});
		if *held.presence.borrow() == nick {
			return;
		}
		glowcap::annotate_session(&held.session, nick.as_deref());
		*held.presence.borrow_mut() = nick;
	}
	/// Every watcher hears each directory event in its own shape.
	pub(super) fn announce(&self, events: &[rooms_application::directory::Event]) {
		for event in events {
			// Drawn once per shape, not once per watcher.
			let drawn = [
				wire::event::<Arguments>(event, Shape::Baseline),
				wire::event::<Arguments>(event, Shape::Publication),
			];
			for (connection, observer, shape) in self.policy.watchers() {
				let args = &drawn[(shape == Shape::Publication) as usize];
				self.tell(connection, observer, NOTIFY, args);
			}
		}
	}
	pub fn tell_member(&self, tell: &Tell<u64, Ref>) {
		self.tell(tell.connection, &tell.inbox, NOTIFY, &notice_args(&tell.notice));
	}
	/// An exchange let go: the originator hears why when there is a why, and
	/// its reply capability goes back either way.
	pub fn reject(&self, dropped: Dropped<u64, Ref>) {
		if let Some(reason) = &dropped.reason {
			self.tell(
				dropped.originator,
				&dropped.reply,
				rooms_application::protocol_data::SIG_REJECT,
				&[Argument::String(reason.clone())],
			);
		}
		self.give_back(dropped.originator, dropped.reply);
	}
	/// Queue one notification on the session `connection` is served over. A
	/// connection that has gone hears nothing and nobody is told: retirement
	/// owns its cleanup. A refusal from a session still open is reported.
	pub fn tell(&self, connection: u64, target: &Ref, verb: &'static str, args: &[Argument]) -> bool {
		let Some(held) = self.connections.get(&connection) else {
			return false;
		};
		match held.session.tell(target, verb, args) {
			Ok(()) => true,
			Err(cause) => {
				if held.session.is_open() {
					self.report(Notice::Undelivered { verb, cause });
				}
				false
			}
		}
	}
	/// Return a capability to the session that imported it. A session that
	/// has closed already let its imports go; dropping the handle then parks
	/// the release for the Host's own cleanup.
	pub fn give_back(&self, connection: u64, capability: Ref) {
		match self.connections.get(&connection) {
			Some(held) if held.session.is_open() => {
				if let Err(cause) = held.session.release(capability) {
					self.report(Notice::ReleaseFailed(cause));
				}
			}
			_ => drop(capability),
		}
	}
}

/// A member notice as its inbox hears it: `[kind, nick, registration id]`.
pub(super) fn notice_args(notice: &MemberNotice) -> [Argument; 3] {
	let (kind, nick, id) = match notice {
		MemberNotice::Registered { nick, id } => (rooms_application::protocol_data::REGISTERED, nick, id),
		MemberNotice::Introducible { nick, id } => ("introducible", nick, id),
		MemberNotice::MintInboxFor { nick, id } => ("mintInboxFor", nick, id),
		MemberNotice::DirectRequested { nick, id } => (rooms_application::protocol_data::DIRECT_REQUESTED, nick, id),
	};
	[kind.into(), nick.as_str().into(), id.as_str().into()]
}
