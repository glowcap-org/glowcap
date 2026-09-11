//! Operator capability admission and durable network/channel mutations.
use super::super::operations::document::Store;
use super::*;
use glowcap::{current_session, Argument};
use rooms_application::{
	failure::FailureCode,
	server::irc::{
		gateway::{self, projection},
		model::{channel_key, BridgeIntent, NetworkChoice},
		registration,
	},
};

type Reply = Result<Argument, String>;
fn one(args: &[Argument], verb: &str) -> Result<String, String> {
	match args {
		[Argument::String(text)] if !text.is_empty() => Ok(text.clone()),
		_ => Err(format!("{verb} needs one nonempty text argument")),
	}
}
pub(in crate::room_server) fn behavior(shared: Shared) -> impl FnMut(&str, &[Argument]) -> Reply {
	move |verb, args| {
		if super::super::operations::carries_capability(args) {
			return Err(format!("IRC gateway {verb} does not take capabilities"));
		}
		if shared.borrow().irc.stopping {
			return Err("the IRC gateway is stopping".into());
		}
		match verb {
			gateway::SNAPSHOT => {
				if !args.is_empty() {
					return Err("snapshot takes no arguments".into());
				}
				projection::describe(&*shared.borrow().irc.core.borrow())?
					.encode()
					.map(Argument::from)
			}
			gateway::OPEN_CONNECTION => {
				let choice = projection::connection_choice(&one(args, verb)?)?;
				validate(&choice)?;
				let gate = shared.borrow_mut().irc.gate(&choice.network);
				let state = shared.borrow();
				let shared = shared.clone();
				state.operations.later(&state, gateway::OPEN_CONNECTION, move |store| {
					Box::pin(async move {
						let _held = gate.lock_owned().await;
						let name = choice.network.clone();
						open(&shared, &store, choice, true).await?;
						Ok(name.into())
					})
				})
			}
			gateway::CONNECTION => {
				let name = one(args, verb)?;
				let network = shared
					.borrow()
					.irc
					.networks
					.get(&network_key(&name))
					.cloned()
					.ok_or("that IRC connection is not open")?;
				let session = current_session()
					.map_err(|e| e.to_string())?
					.ok_or("IRC gateway is reachable only over a session")?;
				session
					.spawn_owned(connection(shared.clone(), network))
					.map(Argument::Reference)
					.map_err(|e| e.to_string())
			}
			_ => Err(format!("IRC gateway has no method {verb}")),
		}
	}
}
fn connection(shared: Shared, network: Rc<Network>) -> impl FnMut(&str, &[Argument]) -> Reply {
	move |verb, args| {
		if super::super::operations::carries_capability(args) {
			return Err(format!("IRC connection {verb} does not take capabilities"));
		}
		current(&shared.borrow(), &network)?;
		let argument = match verb {
			gateway::ADD_LEASE => projection::lease_channel(&one(args, verb)?)?,
			gateway::REMOVE_LEASE => one(args, verb)?,
			gateway::CLOSE_CONNECTION if args.is_empty() => String::new(),
			_ => return Err(format!("IRC connection has no method {verb} with these arguments")),
		};
		let gate = shared.borrow_mut().irc.gate(&network.key);
		let state = shared.borrow();
		let (shared, network) = (shared.clone(), network.clone());
		let method = match verb {
			gateway::ADD_LEASE => gateway::ADD_LEASE,
			gateway::REMOVE_LEASE => gateway::REMOVE_LEASE,
			_ => gateway::CLOSE_CONNECTION,
		};
		state.operations.later(&state, method, move |store| {
			Box::pin(async move {
				let _held = gate.lock_owned().await;
				current(&shared.borrow(), &network)?;
				match method {
					gateway::ADD_LEASE => join(&shared, &store, &network, argument, None)
						.await
						.map(Argument::from),
					gateway::REMOVE_LEASE => part(&shared, &store, &network, argument).await.map(Argument::from),
					_ => {
						close(&shared, &store, &network).await?;
						Ok(Argument::Void)
					}
				}
			})
		})
	}
}
fn validate(choice: &NetworkChoice) -> Result<(), String> {
	choice.validate()?;
	if choice.network.encode_utf16().count() > rooms_application::server::irc::model::MAX_NAME {
		return Err("IRC network name is too long".into());
	}
	crate::irc::Endpoint::new(&choice.host, choice.port, choice.tls)?;
	registration::validate_nick(&choice.nick)?;
	if let Some(sasl) = &choice.sasl {
		if !choice.tls {
			return Err("a registered account needs TLS".into());
		}
		registration::validate_sasl_plain(&sasl.into())?;
	}
	Ok(())
}
pub(super) async fn open(shared: &Shared, store: &Store, choice: NetworkChoice, remember: bool) -> Result<(), String> {
	validate(&choice)?;
	let trust = shared.borrow().irc.trust.clone();
	let tls = if choice.tls {
		Some(trust.get_or_try_init(Tls::system).await?.clone())
	} else {
		None
	};
	if remember {
		store
			.change(
				|current| {
					let mut next = current.clone();
					next.remember_irc_network(choice.clone()).map_err(|e| e.to_string())?;
					Ok(next)
				},
				|_| install_network(shared, choice.clone(), tls),
			)
			.await??;
	} else {
		install_network(shared, choice, tls)?;
	}
	Ok(())
}
fn install_network(shared: &Shared, choice: NetworkChoice, tls: Option<Tls>) -> Result<(), String> {
	let key = choice.key();
	let core = shared.borrow().irc.core.clone();
	core.borrow_mut().open_network(choice).map_err(|e| e.reason())?;
	if shared.borrow().irc.networks.contains_key(&key) {
		return Ok(());
	}
	let (weak, changed) = (Rc::downgrade(shared), Rc::downgrade(shared));
	let (feed, worker) = feed::open(
		core,
		&key,
		tls.clone(),
		move |key, effects| {
			if let Some(shared) = weak.upgrade() {
				apply(&shared.borrow(), key, effects)
			} else {
				Ok(())
			}
		},
		move || {
			if let Some(shared) = changed.upgrade() {
				shared.borrow().changed();
			}
		},
	)?;
	let (done, completed) = watch::channel(false);
	let network = Rc::new(Network {
		key: key.clone(),
		active: Cell::new(true),
		feed,
		done: completed,
		tls,
	});
	let report = Rc::downgrade(shared);
	let mut state = shared.borrow_mut();
	state.irc.networks.insert(key, network);
	state.irc.tasks.spawn_local(async move {
		if let Err(reason) = worker.run().await {
			if let Some(shared) = report.upgrade() {
				trouble(&shared.borrow(), "IRC feed", reason);
			}
		}
		done.send_replace(true);
	});
	state.changed();
	Ok(())
}
pub(super) fn draw() -> Result<[u8; 16], String> {
	let mut bytes = [0; 16];
	getrandom::fill(&mut bytes).map_err(|e| format!("drawing IRC publication entropy failed: {e}"))?;
	Ok(bytes)
}
pub(super) async fn join(
	shared: &Shared,
	store: &Store,
	network: &Rc<Network>,
	channel: String,
	restored: Option<String>,
) -> Result<String, String> {
	current(&shared.borrow(), network)?;
	let key = channel_key(&network.key, &channel);
	let document = store.snapshot().await;
	let id = match restored.or_else(|| {
		document
			.irc_bridges
			.iter()
			.find(|intent| intent.key() == key)
			.map(|intent| intent.publication_id.clone())
	}) {
		Some(id) => id,
		None => rooms_application::directory::registration::Id::from_entropy(draw()?)
			.as_str()
			.into(),
	};
	let entropy = [draw()?, draw()?];
	let core = shared.borrow().irc.core.clone();
	let name = {
		let state = shared.borrow();
		core.borrow_mut()
			.join_bridge(&network.key, &channel, &id, &|name, id| {
				state.native_name_taken(name)
					|| state.foreign.holds_name(name)
					|| state.foreign.by_id(id).is_some()
					|| state.rooms.enter_publication(id).is_ok()
			})
			.map_err(|e| e.reason())?
	};
	let intent = BridgeIntent {
		network: network.key.clone(),
		channel,
		publication_id: id.clone(),
	};
	let outcome = store
		.change(
			|current| {
				let mut next = current.clone();
				let mut draws = entropy.into_iter();
				next.remember_irc_bridge(intent, || draws.next().expect("two bridge authority draws"))
					.map_err(|e| e.to_string())?;
				Ok(next)
			},
			|document| {
				let authority = document
					.irc_bridge_authority(&id)
					.ok_or("the committed IRC bridge has no authority")?
					.clone();
				let publication = Rc::new(Publication {
					key: key.clone(),
					id: id.clone(),
					active: Cell::new(false),
					swiss: RefCell::new(None),
					steward: RefCell::new(None),
					authority: RefCell::new(authority),
					seats: RefCell::new(BTreeMap::new()),
					invitations: RefCell::new(Vec::new()),
				});
				rooms::publish(shared, &publication)?;
				if let Err(reason) = authority::publish(shared, &publication) {
					if let Some(token) = publication.swiss.borrow_mut().take() {
						if let Err(error) = shared.borrow().host.remove_durable(&token) {
							trouble(
								&shared.borrow(),
								"unwinding IRC entrance publication",
								error.to_string(),
							);
						}
					}
					return Err(reason);
				}
				shared
					.borrow_mut()
					.irc
					.publications
					.insert(key.clone(), publication.clone());
				publication.active.set(true);
				core.borrow_mut().started(&key);
				network.feed.changed();
				announce(&shared.borrow(), &key, RoomChange::Opened);
				Ok::<_, String>(())
			},
		)
		.await
		.and_then(|result| result);
	if let Err(reason) = outcome {
		core.borrow_mut().part_bridge(&key);
		return Err(reason);
	}
	shared.borrow().changed();
	Ok(name)
}
pub(super) async fn part(
	shared: &Shared,
	store: &Store,
	network: &Rc<Network>,
	channel: String,
) -> Result<String, String> {
	let key = channel_key(&network.key, &channel);
	let name = shared
		.borrow()
		.irc
		.core
		.borrow()
		.bridge(&key)
		.map(|bridge| bridge.room.name().to_owned())
		.unwrap_or_else(|| format!("{}/{channel}", network.key));
	store
		.change(
			|current| {
				let mut next = current.clone();
				if !next.forget_irc_bridge(&network.key, &channel) {
					return Err("that IRC channel lease is not held".into());
				}
				Ok(next)
			},
			|_| retire(shared, &key),
		)
		.await??;
	network.feed.changed();
	Ok(name)
}
fn retire(shared: &Shared, key: &str) -> Result<(), String> {
	let mut state = shared.borrow_mut();
	let mut failure = None;
	if let Some(publication) = state.irc.publications.remove(key) {
		publication.active.set(false);
		publication.invitations.borrow_mut().clear();
		let ended = format!("{}: This IRC bridge was parted.", FailureCode::RoomRetired.wire());
		let seated: Vec<_> = publication.seats.borrow().keys().copied().collect();
		for connection in seated {
			members::retire(&mut state, &publication, connection, Some(&ended));
		}
		for swiss in [
			publication.steward.borrow_mut().take(),
			publication.swiss.borrow_mut().take(),
		]
		.into_iter()
		.flatten()
		{
			if let Err(error) = state.host.remove_durable(&swiss) {
				failure = Some(error.to_string());
			}
		}
	}
	announce(&state, key, RoomChange::Closed);
	state.irc.core.borrow_mut().part_bridge(key);
	state.changed();
	match failure {
		Some(reason) => Err(reason),
		None => Ok(()),
	}
}
async fn close(shared: &Shared, store: &Store, network: &Rc<Network>) -> Result<(), String> {
	store
		.change(
			|current| {
				let mut next = current.clone();
				if !next.forget_irc_network(&network.key) {
					return Err("that IRC network is not saved".into());
				}
				Ok(next)
			},
			|_| {
				network.active.set(false);
				let keys: Vec<_> = shared
					.borrow()
					.irc
					.core
					.borrow()
					.bridges_of(&network.key)
					.map(|(key, _)| key.to_owned())
					.collect();
				let mut failures = Vec::new();
				for key in keys {
					if let Err(reason) = retire(shared, &key) {
						failures.push(reason);
					}
				}
				network.feed.stop();
				shared.borrow_mut().irc.networks.remove(&network.key);
				failures
			},
		)
		.await?
		.into_iter()
		.for_each(|reason| trouble(&shared.borrow(), "closing IRC network", reason));
	let mut done = network.done.clone();
	while !*done.borrow() {
		done.changed()
			.await
			.map_err(|_| "IRC feed worker ended without closing")?;
	}
	shared
		.borrow_mut()
		.irc
		.core
		.borrow_mut()
		.close_network(&network.key)
		.map_err(|e| e.reason())?;
	shared.borrow().changed();
	Ok(())
}
