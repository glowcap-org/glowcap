//! Who is registered: one name per live connection, the inboxes each member
//! offered for particular peers, the vouchers that carry a name to another
//! connection, and the `webrtc` designators signaling routes by.
mod inboxes;
mod requests;
mod signaling;
use super::{
	DIRECT_REQUEST_COALESCE_MS, Effects, Introduction, MAX_DM_INBOXES, MAX_NAME_VOUCHERS, NAME_VOUCHER_BYTES, Notice,
	Refusal, Tell,
};
use crate::{
	directory::registration::{NicknameAllocation, suggested_nick},
	directory::{Event, Member, MemberChange, registration::Id},
	failure::FailureCode,
	fields::Text,
	room::inbox::nick_refusal,
};
use alloc::{
	collections::{BTreeMap, BTreeSet},
	format,
	rc::Rc,
	string::String,
	vec::Vec,
};

/// What `register` carries once the adapter has read the wire. The adapter
/// parses the locator, because that grammar is the binding's: it says whether
/// the locator names the registering connection and which `webrtc`
/// designator, if any, it routes signaling by.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Register<R> {
	pub nick: String,
	pub allocation: NicknameAllocation,
	pub locator: String,
	/// Whether the connection proved the locator is its own, or nothing could
	/// be checked. Only a keyed connection can be refused here.
	pub own_locator: bool,
	pub webrtc: Option<String>,
	pub inbox: R,
	pub voucher: Option<[u8; NAME_VOUCHER_BYTES]>,
	/// The durable peer identity the connection proved, when it proved one. A
	/// reconnect from the same peer replaces the rows it left behind.
	pub claimant: Option<String>,
}

/// The exact registrations admitted before an inbox capability settles.
/// Completion revalidates both names and capacity. A replacement registration
/// cannot inherit an offer started by its predecessor.
pub struct InboxOffer<C> {
	registry: Rc<()>,
	connection: C,
	owner: Id,
	peer: String,
	target: Id,
	opening: String,
}

struct InboxPeers<'a, C, R> {
	owner: &'a Registration<C, R>,
	recipient: &'a Registration<C, R>,
}

struct Registration<C, R> {
	nick: String,
	id: Id,
	connection: C,
	claimant: Option<String>,
	webrtc: Option<String>,
	inbox: R,
	/// Offers are scoped by peer registration and opening identity.
	offered: inboxes::Offers<R>,
	/// The coalescing window for reciprocal-route notices, per requesting peer.
	requests: BTreeMap<String, u64>,
	signaling: Option<R>,
	vouchers: BTreeSet<[u8; NAME_VOUCHER_BYTES]>,
}

/// One registration as an inventory reads it.
pub struct Face<C> {
	pub nick: String,
	pub id: String,
	pub connection: C,
	/// The registration ids of the peers this member offered an inbox.
	pub offered: Vec<String>,
	pub signaling: bool,
}

pub(super) struct Withdrawn<C, R> {
	pub effects: Effects<C, R>,
	/// Folded nicks whose registrations left, for the exchanges aimed at them.
	pub withdrawn_keys: Vec<String>,
}

pub(super) struct Registry<C, R> {
	identity: Rc<()>,
	rows: BTreeMap<String, Registration<C, R>>,
	by_id: BTreeMap<String, String>,
	by_connection: BTreeMap<C, String>,
	by_claimant: BTreeMap<String, BTreeSet<String>>,
	offerers_by_target: BTreeMap<String, BTreeSet<String>>,
	request_targets_by_requester: BTreeMap<String, BTreeSet<String>>,
	webrtc: BTreeMap<String, String>,
}

impl<C, R> Default for Registry<C, R> {
	fn default() -> Self {
		Self {
			identity: Rc::new(()),
			rows: BTreeMap::new(),
			by_id: BTreeMap::new(),
			by_connection: BTreeMap::new(),
			by_claimant: BTreeMap::new(),
			offerers_by_target: BTreeMap::new(),
			request_targets_by_requester: BTreeMap::new(),
			webrtc: BTreeMap::new(),
		}
	}
}

pub(super) fn fold(nick: &str) -> String {
	nick.to_lowercase()
}

fn same_claimant<C: PartialEq>(held: (C, Option<&str>), caller: (C, Option<&str>)) -> bool {
	held.0 == caller.0 || (held.1.is_some() && held.1 == caller.1)
}

fn member(nick: &str, id: &Id) -> Member {
	Member {
		name: Text(nick.into()),
		registration_id: id.as_str().into(),
	}
}

impl<C: Copy + Ord, R: Clone> Registry<C, R> {
	pub fn nick_of(&self, connection: C) -> Option<&str> {
		self.by_connection
			.get(&connection)
			.and_then(|key| self.rows.get(key))
			.map(|row| row.nick.as_str())
	}
	pub fn registrar(&self, key: &str) -> Option<C> {
		self.rows.get(key).map(|row| row.connection)
	}
	pub fn signaling_of(&self, key: &str) -> Option<(C, R)> {
		let row = self.rows.get(key)?;
		Some((row.connection, row.signaling.clone()?))
	}
	pub fn signaling_target(&self, designator: &str) -> Option<(String, (C, R))> {
		let key = self.webrtc.get(designator)?;
		Some((key.clone(), self.signaling_of(key)?))
	}
	/// Registered members in folded-name order, for discovery.
	pub fn members(&self) -> impl Iterator<Item = Member> + '_ {
		self.rows.values().map(|row| member(&row.nick, &row.id))
	}
	pub fn faces(&self) -> impl Iterator<Item = Face<C>> + '_ {
		self.rows.values().map(|row| Face {
			nick: row.nick.clone(),
			id: row.id.as_str().into(),
			connection: row.connection,
			offered: row.offered.peers(),
			signaling: row.signaling.is_some(),
		})
	}
	/// Take the registration under `nick` out, the way its connection
	/// leaving would.
	pub fn withdraw_nick(&mut self, nick: &str) -> Withdrawn<C, R> {
		let mut withdrawn = Withdrawn {
			effects: Effects::default(),
			withdrawn_keys: Vec::new(),
		};
		self.withdraw(&fold(nick), &mut withdrawn);
		withdrawn
	}
	/// Let go of the inbox `nick` offered the peer registered as `peer`.
	pub fn release_offered(&mut self, nick: &str, peer: &str) -> Option<Vec<super::Release<C, R>>> {
		let key = fold(nick);
		let row = self.rows.get_mut(&key)?;
		let offered = row.offered.withdraw(peer);
		if offered.is_empty() {
			return None;
		}
		remove_index(&mut self.offerers_by_target, peer, &key);
		Some(
			offered
				.into_iter()
				.map(|capability| super::Release {
					connection: row.connection,
					capability,
				})
				.collect(),
		)
	}
	/// Let go of the signaling inbox `nick` offered.
	pub fn release_signaling(&mut self, nick: &str) -> Option<super::Release<C, R>> {
		let row = self.rows.get_mut(&fold(nick))?;
		let signaling = row.signaling.take()?;
		Some(super::Release {
			connection: row.connection,
			capability: signaling,
		})
	}
	pub fn len(&self) -> usize {
		self.rows.len()
	}
	pub fn holds_id(&self, id: &Id) -> bool {
		self.by_id.contains_key(id.as_str())
	}
	/// The connection registered under `nick`, if any.
	pub fn holder_of(&self, nick: &str) -> Option<C> {
		self.rows.get(&fold(nick)).map(|row| row.connection)
	}
	/// Spend one voucher for `nick`: true exactly once per minted voucher,
	/// and only while the registration that minted it stands.
	pub fn redeem(&mut self, nick: &str, voucher: &[u8; NAME_VOUCHER_BYTES]) -> bool {
		self.rows
			.get_mut(&fold(nick))
			.is_some_and(|row| row.vouchers.remove(voucher))
	}
	fn own(&self, connection: C) -> Option<&Registration<C, R>> {
		self.by_connection.get(&connection).and_then(|key| self.rows.get(key))
	}
	pub fn register(
		&mut self,
		connection: C,
		request: Register<R>,
		id: Id,
		_now: u64,
	) -> Result<Withdrawn<C, R>, Refusal> {
		let mut request = request;
		if request.allocation == NicknameAllocation::Automatic {
			request.nick = self.available_nick(&request.nick, connection, request.claimant.as_deref())?;
		}
		let key = fold(&request.nick);
		let caller = (connection, request.claimant.as_deref());
		let held_by_another = self
			.rows
			.get(&key)
			.is_some_and(|holder| !same_claimant((holder.connection, holder.claimant.as_deref()), caller));
		if held_by_another {
			let current = request
				.voucher
				.is_some_and(|voucher| self.rows[&key].vouchers.contains(&voucher));
			if !current {
				return Err(Refusal::coded(
					FailureCode::NickTaken,
					format!(
						"\"{}\" is registered by another member; it frees when they disconnect",
						request.nick
					),
				));
			}
		}
		// First writer holds a `webrtc` designator while its connection stands:
		// accepting a second claim would route every bring-up aimed at the
		// holder into the claimant's inbox.
		if let Some(designator) = &request.webrtc
			&& let Some(holder) = self.webrtc.get(designator).and_then(|held| self.rows.get(held))
		{
			let own_name = fold(&holder.nick) == key;
			if !own_name && !same_claimant((holder.connection, holder.claimant.as_deref()), caller) {
				return Err(Refusal::coded(
					FailureCode::NotYourLocator,
					format!("that webrtc designator is already registered to \"{}\"", holder.nick),
				));
			}
		}
		let mut withdrawn = Withdrawn {
			effects: Effects::default(),
			withdrawn_keys: Vec::new(),
		};
		// A proved peer's reconnect owns one claim, as one connection does:
		// replace every stale row of that same peer before filing this one.
		let mut stale = BTreeSet::new();
		if let Some(held) = self.by_connection.get(&connection).filter(|held| **held != key) {
			stale.insert(held.clone());
		}
		if let Some(claimant) = request.claimant.as_deref()
			&& let Some(held) = self.by_claimant.get(claimant)
		{
			stale.extend(held.iter().filter(|held| held.as_str() != key).cloned());
		}
		for held in stale {
			self.withdraw(&held, &mut withdrawn);
		}
		if held_by_another {
			// Spend the voucher at the commit boundary; the check above proved it.
			let Some(voucher) = request.voucher else {
				return Err(Refusal::coded(
					FailureCode::NickTaken,
					format!("the reconnect proof for \"{}\" is no longer current", request.nick),
				));
			};
			if !self
				.rows
				.get_mut(&key)
				.is_some_and(|holder| holder.vouchers.remove(&voucher))
			{
				return Err(Refusal::coded(
					FailureCode::NickTaken,
					format!("the reconnect proof for \"{}\" is no longer current", request.nick),
				));
			}
		}
		if self.rows.contains_key(&key) {
			self.withdraw(&key, &mut withdrawn);
		}
		if let Some(held) = self.by_connection.remove(&connection) {
			// A connection holds one name at a time: a nick change re-registers.
			self.withdraw(&held, &mut withdrawn);
		}
		let row = Registration {
			nick: request.nick.clone(),
			id: id.clone(),
			connection,
			claimant: request.claimant,
			webrtc: request.webrtc.clone(),
			inbox: request.inbox.clone(),
			offered: Default::default(),
			requests: BTreeMap::new(),
			signaling: None,
			vouchers: BTreeSet::new(),
		};
		self.by_id.insert(id.as_str().into(), key.clone());
		self.by_connection.insert(connection, key.clone());
		if let Some(claimant) = &row.claimant {
			insert_index(&mut self.by_claimant, claimant.clone(), key.clone());
		}
		if let Some(designator) = request.webrtc {
			self.webrtc.insert(designator, key.clone());
		}
		self.rows.insert(key, row);
		withdrawn.effects.tell(
			connection,
			request.inbox,
			Notice::Registered {
				nick: request.nick.clone(),
				id: id.clone(),
			},
		);
		withdrawn.effects.events.push(Event::Member {
			kind: MemberChange::Registered,
			peer: member(&request.nick, &id),
			count: 1,
		});
		Ok(withdrawn)
	}
	fn available_nick(&self, base: &str, connection: C, claimant: Option<&str>) -> Result<String, Refusal> {
		let caller = (connection, claimant);
		let mut candidate = String::from(base);
		// With N occupied names, one of N + 1 sequential candidates is free.
		for _ in 0..=self.rows.len() {
			let available = self
				.rows
				.get(&fold(&candidate))
				.is_none_or(|holder| same_claimant((holder.connection, holder.claimant.as_deref()), caller));
			if available {
				return Ok(candidate);
			}
			candidate = suggested_nick(&candidate);
		}
		Err(Refusal::plain("the directory could not allocate another nickname"))
	}
	pub fn withdraw_connection(&mut self, connection: C) -> Withdrawn<C, R> {
		let mut withdrawn = Withdrawn {
			effects: Effects::default(),
			withdrawn_keys: Vec::new(),
		};
		if let Some(key) = self.by_connection.get(&connection).cloned() {
			self.withdraw(&key, &mut withdrawn);
		}
		withdrawn
	}
	pub fn withdraw_id(&mut self, id: &Id) -> (Option<C>, Withdrawn<C, R>) {
		let mut withdrawn = Withdrawn {
			effects: Effects::default(),
			withdrawn_keys: Vec::new(),
		};
		let key = self.by_id.get(id.as_str()).cloned();
		let connection = key.as_ref().and_then(|key| self.registrar(key));
		if let Some(key) = key {
			self.withdraw(&key, &mut withdrawn);
		}
		(connection, withdrawn)
	}
	/// Take one registration out, announce it, and leave nothing pointing at
	/// the name: the inboxes it collected go back, and so does every inbox
	/// other members offered for it, or the next holder of the name would be
	/// handed what was minted for the last.
	fn withdraw(&mut self, key: &str, withdrawn: &mut Withdrawn<C, R>) {
		let Some(row) = self.rows.remove(key) else {
			return;
		};
		self.by_id.remove(row.id.as_str());
		if let Some(claimant) = &row.claimant {
			remove_index(&mut self.by_claimant, claimant, key);
		}
		if self.by_connection.get(&row.connection).is_some_and(|held| held == key) {
			self.by_connection.remove(&row.connection);
		}
		if let Some(designator) = &row.webrtc
			&& self.webrtc.get(designator).is_some_and(|held| held == key)
		{
			self.webrtc.remove(designator);
		}
		let effects = &mut withdrawn.effects;
		for (target, offered) in row.offered.into_entries() {
			remove_index(&mut self.offerers_by_target, &target, key);
			for inbox in offered.into_values() {
				effects.release(row.connection, inbox);
			}
		}
		for requester in row.requests.keys() {
			remove_index(&mut self.request_targets_by_requester, requester, key);
		}
		if let Some(targets) = self.request_targets_by_requester.remove(row.id.as_str()) {
			for target in targets {
				if let Some(other) = self.rows.get_mut(&target) {
					other.requests.remove(row.id.as_str());
				}
			}
		}
		if let Some(offerers) = self.offerers_by_target.remove(row.id.as_str()) {
			for offerer in offerers {
				if let Some(other) = self.rows.get_mut(&offerer) {
					for offered in other.offered.withdraw(row.id.as_str()) {
						effects.release(other.connection, offered);
					}
				}
			}
		}
		if let Some(signaling) = row.signaling {
			effects.release(row.connection, signaling);
		}
		effects.release(row.connection, row.inbox);
		effects.events.push(Event::Member {
			kind: MemberChange::Unregistered,
			peer: member(&row.nick, &row.id),
			count: 0,
		});
		withdrawn.withdrawn_keys.push(key.into());
	}
	pub fn direct_request_due(&self, connection: C, nick: &str, id: &str, now: u64) -> Result<bool, Refusal> {
		let caller = self
			.own(connection)
			.ok_or_else(|| Refusal::coded(FailureCode::NotRegistered, "requestDirect needs a registered name"))?;
		if self.member_registration(nick)?.as_str() != id {
			return Err(Refusal::coded(
				FailureCode::PeerOffline,
				"direct target registration has changed",
			));
		}
		let target = self
			.rows
			.get(&fold(nick))
			.ok_or_else(|| Refusal::coded(FailureCode::PeerOffline, "direct target registration has changed"))?;
		Ok(target
			.requests
			.get(caller.id.as_str())
			.is_none_or(|prior| now.saturating_sub(*prior) >= DIRECT_REQUEST_COALESCE_MS))
	}
	pub fn request_direct(
		&mut self,
		connection: C,
		nick: &str,
		id: &str,
		now: u64,
	) -> Result<Option<Tell<C, R>>, Refusal> {
		if nick_refusal(nick).is_some() || Id::parse(id).is_err() {
			return Err(Refusal::plain(
				"requestDirect takes a valid registered name and its registration ID",
			));
		}
		let caller = self
			.own(connection)
			.map(|caller| (caller.nick.clone(), caller.id.clone()));
		let target_key = fold(nick);
		let target = self
			.rows
			.get_mut(&target_key)
			.filter(|target| target.id.as_str() == id)
			.ok_or_else(|| {
				Refusal::coded(
					FailureCode::PeerOffline,
					format!("no member named \"{nick}\" is registered"),
				)
			})?;
		let (caller_nick, caller_id) = caller
			.ok_or_else(|| Refusal::coded(FailureCode::NotRegistered, "requestDirect needs a registered name"))?;
		let due = requests::notice_due(&mut target.requests, caller_id.as_str(), now)?;
		let tell = Tell {
			connection: target.connection,
			inbox: target.inbox.clone(),
			notice: Notice::DirectRequested {
				nick: caller_nick,
				id: caller_id.clone(),
			},
		};
		for expired in due.expired {
			remove_index(&mut self.request_targets_by_requester, &expired, &target_key);
		}
		if due.inserted {
			insert_index(
				&mut self.request_targets_by_requester,
				caller_id.as_str().into(),
				target_key,
			);
		}
		if !due.send {
			return Ok(None);
		}
		Ok(Some(tell))
	}
	pub fn member_registration(&self, nick: &str) -> Result<Id, Refusal> {
		if nick_refusal(nick).is_some() {
			return Err(Refusal::plain("memberRegistration takes one valid registered name"));
		}
		self.rows.get(&fold(nick)).map(|row| row.id.clone()).ok_or_else(|| {
			Refusal::coded(
				FailureCode::PeerOffline,
				format!("no member named \"{nick}\" is registered"),
			)
		})
	}
	pub fn voucher(&mut self, id: &Id, bytes: [u8; NAME_VOUCHER_BYTES]) -> Result<(), Refusal> {
		let row = self
			.by_id
			.get(id.as_str())
			.and_then(|key| self.rows.get_mut(key))
			.ok_or_else(|| Refusal::plain("this name capability is no longer current"))?;
		if row.vouchers.len() >= MAX_NAME_VOUCHERS {
			return Err(Refusal::plain(format!(
				"a name may have at most {MAX_NAME_VOUCHERS} vouchers outstanding"
			)));
		}
		row.vouchers.insert(bytes);
		Ok(())
	}
	/// An exact name capability selects its current registration, never the
	/// caller's connection or a replacement that happens to reuse its nickname.
	pub fn registration_connection(&self, id: &Id) -> Result<C, Refusal> {
		self.by_id
			.get(id.as_str())
			.and_then(|key| self.rows.get(key))
			.map(|row| row.connection)
			.ok_or_else(|| Refusal::plain("this name capability is no longer current"))
	}
}

fn insert_index(index: &mut BTreeMap<String, BTreeSet<String>>, subject: String, row: String) {
	index.entry(subject).or_default().insert(row);
}

fn remove_index(index: &mut BTreeMap<String, BTreeSet<String>>, subject: &str, row: &str) {
	let empty = index.get_mut(subject).is_some_and(|rows| {
		rows.remove(row);
		rows.is_empty()
	});
	if empty {
		index.remove(subject);
	}
}
