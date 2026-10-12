//! Bounded offers belong to one peer registration and one direct opening.
//! Introduction transfers the offer. Later openings cannot retain retired inboxes.
use super::*;

/// The directory retains at most MAX_DM_INBOXES actual references per offerer.
/// Keys survive capability settlement and retries. Borrowed lookups make no
/// temporary key copies. Introduction transfers each occurrence out of custody.
pub(super) struct Offers<R> {
	peers: BTreeMap<String, BTreeMap<String, R>>,
	count: usize,
}
impl<R> Default for Offers<R> {
	fn default() -> Self {
		Self {
			peers: BTreeMap::new(),
			count: 0,
		}
	}
}
impl<R> Offers<R> {
	pub fn peers(&self) -> Vec<String> {
		self.peers.keys().cloned().collect()
	}
	pub fn holds_peer(&self, peer: &str) -> bool {
		self.peers.contains_key(peer)
	}
	pub fn holds(&self, peer: &str, opening: &str) -> bool {
		self.peers.get(peer).is_some_and(|held| held.contains_key(opening))
	}
	pub fn admit(&self, peer: &str, opening: &str) -> Result<(), Refusal> {
		if !crate::directory::introduction::valid_opening(opening) {
			return Err(Refusal::plain("a direct opening needs a bounded identity"));
		}
		if !self.peers.get(peer).is_some_and(|held| held.contains_key(opening)) && self.count >= MAX_DM_INBOXES {
			return Err(Refusal::plain(format!(
				"a member may offer at most {MAX_DM_INBOXES} inboxes"
			)));
		}
		Ok(())
	}
	pub fn put(&mut self, peer: &str, opening: &str, inbox: R) -> Option<R> {
		let held = match self.peers.get_mut(peer) {
			Some(held) => held,
			None => self.peers.entry(peer.into()).or_default(),
		};
		if let Some(prior) = held.get_mut(opening) {
			return Some(core::mem::replace(prior, inbox));
		}
		let prior = held.insert(opening.into(), inbox);
		if prior.is_none() {
			self.count += 1;
		}
		prior
	}
	pub fn take(&mut self, peer: &str, opening: &str) -> Option<R> {
		let held = self.peers.get_mut(peer)?;
		let inbox = held.remove(opening)?;
		self.count -= 1;
		if held.is_empty() {
			self.peers.remove(peer);
		}
		Some(inbox)
	}
	pub fn withdraw(&mut self, peer: &str) -> Vec<R> {
		let Some(held) = self.peers.remove(peer) else {
			return Vec::new();
		};
		self.count -= held.len();
		held.into_values().collect()
	}
	pub fn into_entries(self) -> impl Iterator<Item = (String, BTreeMap<String, R>)> {
		self.peers.into_iter()
	}
}

impl<C: Copy + Ord, R: Clone> Registry<C, R> {
	/// Borrow existing offer custody before admission. Reading an offered inbox
	/// does not ask its owner to mint another one. The adapter checks this in the
	/// same synchronous turn as admission and consumption.
	pub fn introduction_ready(&self, connection: C, nick: &str, id: &str, opening: &str) -> bool {
		let Some(caller) = self.own(connection) else {
			return false;
		};
		self.rows
			.get(&fold(nick))
			.is_some_and(|target| target.id.as_str() == id && target.offered.holds(caller.id.as_str(), opening))
	}
	pub fn prepare_inbox(
		&self,
		connection: C,
		for_nick: &str,
		for_id: &str,
		opening: &str,
	) -> Result<InboxOffer<C>, Refusal> {
		let peers = self.check_offer(connection, for_nick, for_id, opening)?;
		Ok(InboxOffer {
			registry: self.identity.clone(),
			connection,
			owner: peers.owner.id.clone(),
			peer: for_nick.into(),
			target: Id::parse(for_id)
				.map_err(|_| Refusal::coded(FailureCode::NickTooLong, "offerInbox has an invalid registration ID"))?,
			opening: opening.into(),
		})
	}
	pub fn complete_inbox(&mut self, offer: InboxOffer<C>, offered: R) -> Result<Effects<C, R>, Refusal> {
		if !Rc::ptr_eq(&offer.registry, &self.identity) {
			return Err(Refusal::plain("the inbox offer belongs to another directory"));
		}
		let peers = self.check_offer(offer.connection, &offer.peer, offer.target.as_str(), &offer.opening)?;
		if peers.owner.id != offer.owner {
			return Err(Refusal::coded(
				FailureCode::NotRegistered,
				"the inbox owner's registration changed before its capability settled",
			));
		}
		let waiting = (peers.recipient.connection, peers.recipient.inbox.clone());
		let gone = || {
			Refusal::coded(
				FailureCode::NotRegistered,
				"the inbox owner's registration changed before its capability settled",
			)
		};
		let own_key = self.by_connection.get(&offer.connection).ok_or_else(gone)?;
		let own = self.rows.get_mut(own_key).ok_or_else(gone)?;
		let mut effects = Effects::default();
		if let Some(prior) = own.offered.put(offer.target.as_str(), &offer.opening, offered) {
			effects.release(offer.connection, prior);
		}
		insert_index(
			&mut self.offerers_by_target,
			offer.target.as_str().into(),
			own_key.clone(),
		);
		effects.tell(
			waiting.0,
			waiting.1,
			Notice::Introducible {
				nick: own.nick.clone(),
				id: own.id.clone(),
				opening: offer.opening,
			},
		);
		Ok(effects)
	}
	fn check_offer(
		&self,
		connection: C,
		for_nick: &str,
		for_id: &str,
		opening: &str,
	) -> Result<InboxPeers<'_, C, R>, Refusal> {
		if let Some(refusal) = nick_refusal(for_nick).or_else(|| {
			Id::parse(for_id)
				.is_err()
				.then(|| "offerInbox has an invalid registration ID".into())
		}) {
			return Err(Refusal::coded(FailureCode::NickTooLong, refusal));
		}
		let own = self
			.own(connection)
			.ok_or_else(|| Refusal::coded(FailureCode::NotRegistered, "offerInbox needs a registered name"))?;
		let waiting = self
			.rows
			.get(&fold(for_nick))
			.filter(|waiting| waiting.id.as_str() == for_id)
			.ok_or_else(|| {
				Refusal::coded(
					FailureCode::PeerOffline,
					format!("the registration for \"{for_nick}\" changed before its inbox arrived"),
				)
			})?;
		own.offered.admit(for_id, opening)?;
		Ok(InboxPeers {
			owner: own,
			recipient: waiting,
		})
	}
	pub fn introduce(
		&mut self,
		connection: C,
		nick: &str,
		id: &str,
		opening: &str,
	) -> Result<Introduction<C, R>, Refusal> {
		if nick_refusal(nick).is_some()
			|| Id::parse(id).is_err()
			|| !crate::directory::introduction::valid_opening(opening)
		{
			return Err(Refusal::plain(
				"introduce takes a registered name, registration ID and opening identity",
			));
		}
		let caller = self
			.own(connection)
			.map(|caller| (caller.nick.clone(), caller.id.clone()))
			.ok_or_else(|| Refusal::coded(FailureCode::NotRegistered, "introduce needs a registered name"))?;
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
		if let Some(inbox) = target.offered.take(caller.1.as_str(), opening) {
			if !target.offered.holds_peer(caller.1.as_str()) {
				remove_index(&mut self.offerers_by_target, caller.1.as_str(), &target_key);
			}
			return Ok(Introduction::Inbox(inbox));
		}
		Ok(Introduction::Pending(Tell {
			connection: target.connection,
			inbox: target.inbox.clone(),
			notice: Notice::MintInboxFor {
				nick: caller.0,
				id: caller.1,
				opening: opening.into(),
			},
		}))
	}
}
