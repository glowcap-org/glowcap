//! The server's IRC gateway. Portable policy owns networks, rooms and seats;
//! this owner composes their capabilities, durable names and native sockets.
pub(super) mod authority;
mod commands;
mod invitation;
mod members;
pub(super) mod operator;
pub(super) mod rooms;
pub(super) use commands::behavior;

use super::{
	notice::Notice,
	state::{Shared, State},
};
use crate::irc::{feed, Tls};
use glowcap::Ref;
use rooms_application::{
	directory::{Event, RoomChange},
	server::irc::{
		gateway::Gateway,
		model::{network_key, BridgeAuthority},
		room::Effects,
	},
};
use std::{
	cell::{Cell, RefCell},
	collections::BTreeMap,
	rc::Rc,
	sync::{Arc, Weak},
};
use tokio::sync::{watch, Mutex, OnceCell};

type Core = Gateway<u64, Ref>;
pub(super) struct Network {
	key: String,
	active: Cell<bool>,
	feed: feed::Feed,
	done: watch::Receiver<bool>,
	tls: Option<Tls>,
}
pub(super) struct Publication {
	pub key: String,
	pub id: String,
	pub active: Cell<bool>,
	pub swiss: RefCell<Option<String>>,
	steward: RefCell<Option<String>>,
	authority: RefCell<BridgeAuthority>,
	seats: RefCell<BTreeMap<u64, Rc<members::Seat>>>,
	invitations: RefCell<Vec<Rc<RefCell<rooms_application::server::invitation::Admission>>>>,
}
#[derive(Default)]
pub(super) struct Runtime {
	pub core: Rc<RefCell<Core>>,
	networks: BTreeMap<String, Rc<Network>>,
	pub publications: BTreeMap<String, Rc<Publication>>,
	gates: BTreeMap<String, Weak<Mutex<()>>>,
	identity_gates: BTreeMap<(u64, String), Weak<Mutex<()>>>,
	trust: Rc<OnceCell<Tls>>,
	identities: BTreeMap<(u64, String), Rc<members::Identity>>,
	pub tasks: tokio::task::JoinSet<()>,
	stopping: bool,
	next_member: u64,
}
impl Runtime {
	fn gate(&mut self, network: &str) -> Arc<Mutex<()>> {
		self.gates.retain(|_, held| held.strong_count() != 0);
		let key = network_key(network);
		if let Some(held) = self.gates.get(&key).and_then(Weak::upgrade) {
			return held;
		}
		let gate = Arc::new(Mutex::new(()));
		self.gates.insert(key, Arc::downgrade(&gate));
		gate
	}
	pub fn holds_name(&self, name: &str) -> bool {
		self.core.borrow().holds_name(name)
	}
	pub fn stop(&mut self) {
		self.stopping = true;
		for network in self.networks.values() {
			network.feed.stop();
		}
		for identity in self.identities.values() {
			identity.member.stop();
		}
	}
}

fn current(state: &State, network: &Rc<Network>) -> Result<(), String> {
	if network.active.get()
		&& state
			.irc
			.networks
			.get(&network.key)
			.is_some_and(|held| Rc::ptr_eq(held, network))
	{
		Ok(())
	} else {
		Err("this IRC connection capability was closed".into())
	}
}
fn retired() -> String {
	format!(
		"{}: this IRC bridge publication was retired",
		rooms_application::failure::FailureCode::RoomRetired.wire()
	)
}

fn apply(state: &State, key: &str, mut effects: Effects<u64, Ref>) -> Result<(), String> {
	let delivery = if effects.relay.is_empty() {
		Ok(())
	} else {
		let core = state.irc.core.borrow();
		let bridge = core.bridge(key).ok_or_else(retired)?;
		let network = state.irc.networks.get(&bridge.network).ok_or_else(retired)?;
		network
			.feed
			.apply(key, bridge.room.publication_id(), std::mem::take(&mut effects.relay))
	};
	for (connection, inbox, notice) in effects.tells {
		if let Some(session) = state.session(connection) {
			let args =
				rooms_application::server::irc::wire::arguments(&notice, &mut super::files::Minter { state, session });
			state.tell(connection, &inbox, rooms_application::room::inbox::NOTIFY, &args);
		}
	}
	for (connection, inbox) in effects.releases {
		state.give_back(connection, inbox);
	}
	for connection in effects.presence {
		state.state_presence(connection);
	}
	if effects.count_changed {
		announce(state, key, RoomChange::Count);
	}
	state.changed();
	delivery
}
fn announce(state: &State, key: &str, kind: RoomChange) {
	if let Some(bridge) = state.irc.core.borrow().bridge(key) {
		state.announce(&[Event::Room {
			kind,
			entry: bridge.room.info(),
		}]);
	}
}
fn trouble(state: &State, source: &str, reason: String) {
	state.report(Notice::Trouble {
		source: source.into(),
		reason,
	});
}

pub(super) async fn restore(shared: &Shared, store: &super::operations::document::Store) {
	let document = store.snapshot().await;
	for choice in document.irc_networks {
		if let Err(reason) = commands::open(shared, store, choice, false).await {
			trouble(&shared.borrow(), "restoring an IRC network", reason);
		}
	}
	for intent in document.irc_bridges {
		let network = shared.borrow().irc.networks.get(&network_key(&intent.network)).cloned();
		if let Some(network) = network {
			if let Err(reason) =
				commands::join(shared, store, &network, intent.channel, Some(intent.publication_id)).await
			{
				trouble(&shared.borrow(), "restoring an IRC channel", reason);
			}
		}
	}
}

pub(super) fn departed(state: &mut State, connection: u64) {
	let publications: Vec<_> = state.irc.publications.values().cloned().collect();
	for publication in publications {
		members::retire(state, &publication, connection, None);
	}
}
