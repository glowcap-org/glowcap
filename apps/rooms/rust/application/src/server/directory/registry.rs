//! Who is registered: one name per live connection, the inboxes each member
//! offered for particular peers, the vouchers that carry a name to another
//! connection, and the `webrtc` designators signaling routes by.
use super::{
	Effects, Introduction, Notice, Refusal, Tell, DIRECT_REQUEST_COALESCE_MS, MAX_DM_INBOXES, MAX_NAME_VOUCHERS,
	NAME_VOUCHER_BYTES,
};
use crate::{
	directory::{registration::Id, Event, Member, MemberChange},
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
/// Completion revalidates both names and capacity; a replacement registration
/// cannot inherit an offer started by its predecessor.
pub struct InboxOffer<C> {
	registry: Rc<()>,
	connection: C,
	owner: Id,
	peer: String,
	target: Id,
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
	/// The inbox this member offered for each peer, by that peer's
	/// registration id, so a later holder of the same nick cannot inherit it.
	offered: BTreeMap<String, R>,
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
	webrtc: BTreeMap<String, String>,
}

impl<C, R> Default for Registry<C, R> {
	fn default() -> Self {
		Self {
			identity: Rc::new(()),
			rows: BTreeMap::new(),
			by_id: BTreeMap::new(),
			by_connection: BTreeMap::new(),
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
			offered: row.offered.keys().cloned().collect(),
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
	pub fn release_offered(&mut self, nick: &str, peer: &str) -> Option<super::Release<C, R>> {
		let row = self.rows.get_mut(&fold(nick))?;
		let offered = row.offered.remove(peer)?;
		Some(super::Release {
			connection: row.connection,
			capability: offered,
		})
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
				return Err(Refusal::new(
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
		if let Some(designator) = &request.webrtc {
			if let Some(holder) = self.webrtc.get(designator).and_then(|held| self.rows.get(held)) {
				let own_name = fold(&holder.nick) == key;
				if !own_name && !same_claimant((holder.connection, holder.claimant.as_deref()), caller) {
					return Err(Refusal::new(
						FailureCode::NotYourLocator,
						format!("that webrtc designator is already registered to \"{}\"", holder.nick),
					));
				}
			}
		}
		let mut withdrawn = Withdrawn {
			effects: Effects::default(),
			withdrawn_keys: Vec::new(),
		};
		// A proved peer's reconnect owns one claim, as one connection does:
		// replace every stale row of that same peer before filing this one.
		let stale: Vec<String> = self
			.rows
			.iter()
			.filter(|(held, row)| **held != key && same_claimant((row.connection, row.claimant.as_deref()), caller))
			.map(|(held, _)| held.clone())
			.collect();
		for held in stale {
			self.withdraw(&held, &mut withdrawn);
		}
		if held_by_another {
			// Spend the voucher at the commit boundary; the check above proved it.
			let voucher = request.voucher.expect("a current voucher was checked");
			if !self
				.rows
				.get_mut(&key)
				.is_some_and(|holder| holder.vouchers.remove(&voucher))
			{
				return Err(Refusal::new(
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
			offered: BTreeMap::new(),
			requests: BTreeMap::new(),
			signaling: None,
			vouchers: BTreeSet::new(),
		};
		self.by_id.insert(id.as_str().into(), key.clone());
		self.by_connection.insert(connection, key.clone());
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
	/// Take one registration out, announce it, and leave nothing pointing at
	/// the name: the inboxes it collected go back, and so does every inbox
	/// other members offered for it, or the next holder of the name would be
	/// handed what was minted for the last.
	fn withdraw(&mut self, key: &str, withdrawn: &mut Withdrawn<C, R>) {
		let Some(row) = self.rows.remove(key) else {
			return;
		};
		self.by_id.remove(row.id.as_str());
		if self.by_connection.get(&row.connection).is_some_and(|held| held == key) {
			self.by_connection.remove(&row.connection);
		}
		if let Some(designator) = &row.webrtc {
			if self.webrtc.get(designator).is_some_and(|held| held == key) {
				self.webrtc.remove(designator);
			}
		}
		let effects = &mut withdrawn.effects;
		for (_, offered) in row.offered {
			effects.release(row.connection, offered);
		}
		for other in self.rows.values_mut() {
			other.requests.remove(row.id.as_str());
			if let Some(offered) = other.offered.remove(row.id.as_str()) {
				effects.release(other.connection, offered);
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
	pub fn prepare_inbox(&self, connection: C, for_nick: &str, for_id: &str) -> Result<InboxOffer<C>, Refusal> {
		let peers = self.check_offer(connection, for_nick, for_id)?;
		Ok(InboxOffer {
			registry: self.identity.clone(),
			connection,
			owner: peers.owner.id.clone(),
			peer: for_nick.into(),
			target: Id::parse(for_id).expect("validated registration"),
		})
	}
	pub fn complete_inbox(&mut self, offer: InboxOffer<C>, offered: R) -> Result<Effects<C, R>, Refusal> {
		if !Rc::ptr_eq(&offer.registry, &self.identity) {
			return Err(Refusal::plain("the inbox offer belongs to another directory"));
		}
		let peers = self.check_offer(offer.connection, &offer.peer, offer.target.as_str())?;
		if peers.owner.id != offer.owner {
			return Err(Refusal::new(
				FailureCode::NotRegistered,
				"the inbox owner's registration changed before its capability settled",
			));
		}
		let waiting = (peers.recipient.connection, peers.recipient.inbox.clone());
		let own_key = self.by_connection.get(&offer.connection).expect("validated connection");
		let own = self.rows.get_mut(own_key).expect("validated registration");
		let mut effects = Effects::default();
		if let Some(prior) = own.offered.insert(offer.target.as_str().into(), offered) {
			effects.release(offer.connection, prior);
		}
		effects.tell(
			waiting.0,
			waiting.1,
			Notice::Introducible {
				nick: own.nick.clone(),
				id: own.id.clone(),
			},
		);
		Ok(effects)
	}
	fn check_offer(&self, connection: C, for_nick: &str, for_id: &str) -> Result<InboxPeers<'_, C, R>, Refusal> {
		let target_id = Id::parse(for_id).ok();
		if let Some(refusal) = nick_refusal(for_nick).or_else(|| {
			target_id
				.is_none()
				.then(|| "offerInbox has an invalid registration ID".into())
		}) {
			return Err(Refusal::new(FailureCode::NickTooLong, refusal));
		}
		let Some(own) = self.own(connection) else {
			return Err(Refusal::new(
				FailureCode::NotRegistered,
				"offerInbox needs a registered name",
			));
		};
		let waiting_key = fold(for_nick);
		let waiting = self
			.rows
			.get(&waiting_key)
			.filter(|waiting| waiting.id.as_str() == for_id)
			.ok_or_else(|| {
				Refusal::new(
					FailureCode::PeerOffline,
					format!("the registration for \"{for_nick}\" changed before its inbox arrived"),
				)
			})?;
		if !own.offered.contains_key(for_id) && own.offered.len() >= MAX_DM_INBOXES {
			return Err(Refusal::plain(format!(
				"a member may offer at most {MAX_DM_INBOXES} inboxes"
			)));
		}
		Ok(InboxPeers {
			owner: own,
			recipient: waiting,
		})
	}

	pub fn introduce(&self, connection: C, nick: &str, id: &str) -> Result<Introduction<C, R>, Refusal> {
		if nick_refusal(nick).is_some() || Id::parse(id).is_err() {
			return Err(Refusal::plain(
				"introduce takes a valid registered name and its registration ID",
			));
		}
		let target = self
			.rows
			.get(&fold(nick))
			.filter(|target| target.id.as_str() == id)
			.ok_or_else(|| {
				Refusal::new(
					FailureCode::PeerOffline,
					format!("no member named \"{nick}\" is registered"),
				)
			})?;
		let caller = self
			.own(connection)
			.ok_or_else(|| Refusal::new(FailureCode::NotRegistered, "introduce needs a registered name"))?;
		Ok(match target.offered.get(caller.id.as_str()) {
			Some(inbox) => Introduction::Inbox(inbox.clone()),
			None => Introduction::Pending(Tell {
				connection: target.connection,
				inbox: target.inbox.clone(),
				notice: Notice::MintInboxFor {
					nick: caller.nick.clone(),
					id: caller.id.clone(),
				},
			}),
		})
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
		let target = self
			.rows
			.get_mut(&fold(nick))
			.filter(|target| target.id.as_str() == id)
			.ok_or_else(|| {
				Refusal::new(
					FailureCode::PeerOffline,
					format!("no member named \"{nick}\" is registered"),
				)
			})?;
		let (caller_nick, caller_id) =
			caller.ok_or_else(|| Refusal::new(FailureCode::NotRegistered, "requestDirect needs a registered name"))?;
		if !notice_due(&mut target.requests, caller_id.as_str(), now)? {
			return Ok(None);
		}
		Ok(Some(Tell {
			connection: target.connection,
			inbox: target.inbox.clone(),
			notice: Notice::DirectRequested {
				nick: caller_nick,
				id: caller_id,
			},
		}))
	}
	pub fn member_registration(&self, nick: &str) -> Result<Id, Refusal> {
		if nick_refusal(nick).is_some() {
			return Err(Refusal::plain("memberRegistration takes one valid registered name"));
		}
		self.rows.get(&fold(nick)).map(|row| row.id.clone()).ok_or_else(|| {
			Refusal::new(
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
	pub fn offer_signaling(&mut self, connection: C, inbox: R) -> Result<Option<super::Release<C, R>>, Refusal> {
		let Some(key) = self.by_connection.get(&connection).cloned() else {
			return Err(Refusal::new(
				FailureCode::NotRegistered,
				"offerSignaling needs a registered name",
			));
		};
		let row = self.rows.get_mut(&key).expect("a registered connection has its row");
		Ok(row
			.signaling
			.replace(inbox)
			.map(|capability| super::Release { connection, capability }))
	}
}

/// Whether a reciprocal-route notice is due for `peer`. The map is a
/// coalescing window, not a history: expired rows leave lazily at the
/// capacity boundary, so a peer can force at most one bounded scan.
fn notice_due(requests: &mut BTreeMap<String, u64>, peer: &str, now: u64) -> Result<bool, Refusal> {
	if let Some(prior) = requests.get(peer) {
		if now.saturating_sub(*prior) < DIRECT_REQUEST_COALESCE_MS {
			return Ok(false);
		}
	} else if requests.len() >= MAX_DM_INBOXES {
		requests.retain(|_, at| now.saturating_sub(*at) < DIRECT_REQUEST_COALESCE_MS);
		if requests.len() >= MAX_DM_INBOXES {
			return Err(Refusal::plain(format!(
				"a member may track at most {MAX_DM_INBOXES} reciprocal direct requests"
			)));
		}
	}
	requests.insert(peer.into(), now);
	Ok(true)
}
