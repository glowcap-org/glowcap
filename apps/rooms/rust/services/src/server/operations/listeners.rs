//! The listener seats over this server's Host: every `up` opens one more
//! listener sharing the Host's identity and serves its partners the same
//! way the boot listener does, `down` closes it, and what an operator asked
//! to keep is written to `operations.json` before the row exists. The
//! policy in `rooms_application::server::operations::listeners` decides.
//! This owns the sockets and the file.
use super::super::{
	notice::Notice,
	state::{Shared, State, Work},
};
use super::document::Store;
use glowcap::{Argument, ListenerIdentity};
use rooms_application::server::operations::listeners::{
	self, Ask, Environment, Refusal, Seats, Transport, register_url,
};
use rooms_platform::serving::{Listener, iroh_config};
use std::{rc::Rc, time::Duration};

const LIST: &str = "list";
const UP: &str = "up";
const DOWN: &str = "down";
/// How long a relay registration may take before the `up` refuses instead
/// of answering a row nothing stands behind.
const RELAY_REGISTER_DEADLINE: Duration = Duration::from_secs(5);

/// The process environment, the one the seats' hints and defaults read.
pub(crate) struct Env;
impl Environment for Env {
	fn env(&self, name: &str) -> Option<String> {
		std::env::var(name)
			.ok()
			.map(|value| value.trim().to_owned())
			.filter(|value| !value.is_empty())
	}
}

/// One live listener beyond the policy's row. The peer owns the task
/// admitting its partners, including partners surviving a listener down.
struct Live {
	listener: Rc<Listener>,
}

/// The listener seats and the sockets implementing them.
pub(crate) struct Registry {
	pub seats: Seats,
	live: std::collections::BTreeMap<u64, Live>,
	changing: std::collections::BTreeSet<Transport>,
}

impl Registry {
	pub fn new() -> Self {
		Self {
			seats: Seats::default(),
			live: Default::default(),
			changing: Default::default(),
		}
	}
	/// Every live locator, for the route a caller is advertised.
	pub fn locators(&self) -> Vec<(Transport, String)> {
		self.seats
			.live()
			.map(|row| (row.transport, row.locator.clone()))
			.collect()
	}
	/// Take every runtime listener out of the seats for a shutdown to close.
	/// The peer joins their accepted sessions once the Host has retired.
	pub fn drain(&mut self) -> Vec<Rc<Listener>> {
		let rows = self.seats.drain();
		rows.into_iter()
			.filter_map(|row| self.live.remove(&row.id))
			.map(|live| live.listener)
			.collect()
	}
}

/// One in-flight lifecycle change per transport. The command owns this
/// claim through preparation, commit, and socket cleanup.
struct Changing {
	shared: Shared,
	transport: Transport,
}
impl Changing {
	fn take(shared: &Shared, transport: Transport) -> Result<Self, Refusal> {
		if !shared.borrow_mut().listeners.changing.insert(transport) {
			return Err(Refusal::coded(
				rooms_application::failure::FailureCode::ListenerTransportHeld,
				format!("the {} listener is changing", transport.name()),
			));
		}
		Ok(Self {
			shared: shared.clone(),
			transport,
		})
	}
}
impl Drop for Changing {
	fn drop(&mut self) {
		self.shared.borrow_mut().listeners.changing.remove(&self.transport);
	}
}

/// The transport a boot listener stands in.
pub(crate) fn boot_transport(transport: &rooms_platform::serving::Transport) -> Transport {
	match transport {
		rooms_platform::serving::Transport::Tcp { .. } => Transport::Tcp,
		rooms_platform::serving::Transport::Iroh(_) => Transport::Iroh,
		rooms_platform::serving::Transport::Onion(_) => Transport::Onion,
	}
}

/// Adopt the boot listener the peer opened and announced. Its partners are
/// served by the peer's own loop, so no accept task is spawned here.
pub(crate) fn adopt_boot(state: &mut State, transport: Transport, locator: String) {
	state.listeners.seats.adopt_boot(transport, locator);
}

/// Replay the kept intents: each seat not already held comes up without
/// being remembered again, and one that cannot is noted rather than fatal.
pub(crate) async fn restore(shared: &Shared, writer: &Store) {
	let intents = writer.snapshot().await.listeners;
	for intent in intents {
		if shared.borrow().listeners.seats.held(intent.transport).is_some() {
			continue;
		}
		if let Err(refusal) = up(shared, writer, intent.transport, Ask::from_intent(&intent), false).await {
			shared.borrow().report(Notice::Trouble {
				source: format!("could not restore the {} listener", intent.transport.name()),
				reason: refusal.reason(),
			});
		}
	}
}

/// Bring `transport` up. Order: the policy admits, the socket opens, the
/// intent is persisted, the row exists, its partners are served, and the
/// announced listener is selected again as the Host's location, because the
/// binding moved the selection to the newest one.
async fn up(shared: &Shared, writer: &Store, transport: Transport, ask: Ask, remember: bool) -> Result<u64, Refusal> {
	let host = {
		let state = shared.borrow();
		state.listeners.seats.admit(transport, &Env)?;
		state.host.clone()
	};
	let _claim = Changing::take(shared, transport)?;
	let accepting = shared
		.borrow()
		.work
		.clone()
		.try_reserve_owned()
		.map_err(|_| Refusal::plain("the server is busy admitting listeners; try again"))?;
	let (listener, locator) = bring_up(&host, transport, &ask).await?;
	let listener = Rc::new(listener);
	let install = || {
		let mut state = shared.borrow_mut();
		let id = state.listeners.seats.brought_up(transport, locator, true);
		accepting.send(Work::Task(Box::pin(admit(shared.clone(), listener.clone()))));
		state.listeners.live.insert(
			id,
			Live {
				listener: listener.clone(),
			},
		);
		id
	};
	let id = if remember {
		let result = writer
			.change(
				|current| {
					let mut next = current.clone();
					next.remember_listener(ask.intent(transport))
						.map_err(|e| e.to_string())?;
					Ok(next)
				},
				|_| install(),
			)
			.await;
		match result {
			Ok(id) => id,
			Err(reason) => {
				if let Err(cleanup) = listener.close().await {
					shared.borrow().report(Notice::Trouble {
						source: "closing a listener whose intent could not be kept".into(),
						reason: cleanup.to_string(),
					});
				}
				reselect(shared);
				return Err(Refusal::plain(reason));
			}
		}
	} else {
		install()
	};
	reselect(shared);
	Ok(id)
}

/// The listener carrying the announced locator selects itself as the Host's
/// signed location again. The boot listener is the peer's own. A runtime
/// listener re-selects through its row.
fn reselect(shared: &Shared) {
	let state = shared.borrow();
	let Some(serving) = state
		.listeners
		.seats
		.live()
		.find(|row| state.listeners.seats.serving(row))
	else {
		return;
	};
	let outcome = match state.listeners.live.get(&serving.id) {
		Some(live) => live.listener.select(),
		None => state.boot_listener.as_ref().map_or(Ok(()), |boot| boot.select()),
	};
	if let Err(error) = outcome {
		state.report(Notice::ListenerSelectFailed(*error));
	}
}

/// Serve a runtime listener's partners the way the boot listener's are
/// served, until it closes.
async fn admit(shared: Shared, listener: Rc<Listener>) {
	let mut served = tokio::task::JoinSet::new();
	loop {
		match listener.accept().await {
			Ok(session) => {
				let report = shared.borrow().reporter();
				served.spawn_local(super::super::peer::served(shared.clone(), session, report));
			}
			Err(error) if rooms_platform::serving::accept_ended(&error) => break,
			Err(error) => {
				shared
					.borrow()
					.report(Notice::Partner(rooms_platform::serving::PartnerNotice::AcceptRefused(
						error,
					)));
				tokio::time::sleep(rooms_platform::serving::ACCEPT_RETRY).await;
			}
		}
	}
	while let Some(ended) = served.join_next().await {
		if let Err(join) = ended {
			shared
				.borrow()
				.report(Notice::Partner(rooms_platform::serving::PartnerNotice::TaskFailed(
					join,
				)));
		}
	}
}

async fn down(shared: &Shared, writer: &Store, id: u64) -> Result<(), Refusal> {
	let (transport, managed) = {
		let state = shared.borrow();
		let row = state.listeners.seats.take_down(id)?;
		(row.transport, row.managed)
	};
	let _claim = Changing::take(shared, transport)?;
	// Desired state commits first, and the runtime row retires in that
	// same serialized installation, before closing its socket outside it.
	let retire = || {
		let mut state = shared.borrow_mut();
		state.listeners.seats.went_down(id);
		state.listeners.live.remove(&id)
	};
	let live = if managed {
		writer
			.change(
				|current| {
					let mut next = current.clone();
					next.forget_listener(transport);
					Ok(next)
				},
				|_| retire(),
			)
			.await
			.map_err(Refusal::plain)?
	} else {
		retire()
	};
	if let Some(live) = live {
		live.listener
			.close()
			.await
			.map_err(|error| Refusal::plain(format!("closing the listener failed: {error}")))?;
	}
	Ok(())
}

/// Open the socket for one seat. Each family reads its defaults from the
/// environment the seat's hints named, so a blank field means what the
/// list said it means.
async fn bring_up(host: &glowcap::Host, transport: Transport, ask: &Ask) -> Result<(Listener, String), Refusal> {
	let env = Env;
	if transport.is_tcp_family() {
		let bind = ask
			.bind
			.clone()
			.or_else(|| env.env("GLOWCAP_ROOMS_BIND"))
			.unwrap_or_else(|| "127.0.0.1".into());
		let port = ask.port.unwrap_or(0);
		let options = glowcap::tcp::ListenOptions {
			identity: ListenerIdentity::Host(host.clone()),
			advertised_host: ask.advertise.clone().or_else(|| env.env("GLOWCAP_ROOMS_ANNOUNCE_HOST")),
			..Default::default()
		};
		let server = match transport {
			Transport::Tcp => glowcap::tcp::listen(&bind, port, options).await,
			Transport::KeyedTcp => glowcap::tcp::keyed::listen(&bind, port, options).await,
			_ => glowcap::tcp::noise::listen(&bind, port, options).await,
		}
		.map_err(|error| Refusal::plain(rooms_platform::serving::BindError::new(&bind, port, error).to_string()))?;
		// The keyed and sealed profiles announce their complete locator
		// because the key, not the address, is the name a peer dials.
		let locator = if transport == Transport::Tcp {
			server.locator().map_err(|e| Refusal::plain(e.to_string()))?.designator
		} else {
			server.uri().map_err(|e| Refusal::plain(e.to_string()))?
		};
		return Ok((Listener::Tcp(server), locator));
	}
	if transport.is_relay_family() {
		let route = ask
			.relay
			.clone()
			.or_else(|| env.env("GLOWCAP_ROOMS_RELAY_URL"))
			.ok_or_else(|| {
				Refusal::unsupported(format!(
					"A {} listener registers at a relay. Name its WebSocket URL with the ask, or start the server with GLOWCAP_ROOMS_RELAY_URL.",
					transport.name()
				))
			})?;
		let register = register_url(&route)?;
		let designator = host.designator().map_err(|e| Refusal::plain(e.to_string()))?;
		probe_register_endpoint(&register, &designator).await?;
		let options = glowcap::relay::ListenOptions {
			identity: ListenerIdentity::Host(host.clone()),
			trust: Default::default(),
		};
		let listen = async {
			if transport == Transport::KeyedRelay {
				glowcap::relay::keyed::listen(&route, &register, options).await
			} else {
				glowcap::relay::noise::listen(&route, &register, options).await
			}
		};
		let server = tokio::time::timeout(RELAY_REGISTER_DEADLINE, listen)
			.await
			.map_err(|_| Refusal::unsupported("The relay did not answer a register socket in time."))?
			.map_err(|error| Refusal::plain(error.to_string()))?;
		let locator = server.uri().map_err(|e| Refusal::plain(e.to_string()))?;
		return Ok((Listener::Relay(server), locator));
	}
	match transport {
		Transport::Iroh => {
			let reachability = match env.env("GLOWCAP_ROOMS_REACHABILITY").as_deref() {
				None | Some("direct") => glowcap::iroh::Reachability::Direct,
				Some("discovery") => glowcap::iroh::Reachability::Discovery,
				Some(other) => {
					return Err(Refusal::plain(format!(
						"unknown reachability \"{other}\" (expected direct or discovery)"
					)));
				}
			};
			let server = glowcap::iroh::listen(
				iroh_config(reachability),
				glowcap::iroh::ListenOptions {
					identity: ListenerIdentity::Host(host.clone()),
				},
			)
			.await
			.map_err(|error| Refusal::plain(error.to_string()))?;
			let locator = if reachability == glowcap::iroh::Reachability::Discovery {
				let node = server.node_id().to_owned();
				glowcap::format_locator_uri(&glowcap::iroh::locator(&node, None))
					.map_err(|e| Refusal::plain(e.to_string()))?
			} else {
				server.uri().map_err(|e| Refusal::plain(e.to_string()))?
			};
			Ok((Listener::Iroh(server), locator))
		}
		Transport::Onion => {
			// glowcap starts no Tor, so the endpoints of an already-running
			// daemon must have arrived in the environment. A runtime service
			// takes a fresh address: the stored key belongs to the boot service.
			let (Some(socks), Some(control)) = (env.env("GLOWCAP_ONION_SOCKS"), env.env("GLOWCAP_ONION_CONTROL"))
			else {
				return Err(Refusal::unsupported(listeners::ONION_NEEDS_TOR));
			};
			let config = glowcap::onion::Config::dial_only(&socks).with_control(&control, glowcap::onion::Auth::None);
			let server = glowcap::onion::listen(
				config,
				glowcap::onion::ListenOptions {
					identity: ListenerIdentity::Host(host.clone()),
				},
			)
			.await
			.map_err(|error| Refusal::plain(error.to_string()))?;
			let locator = server.uri().map_err(|e| Refusal::plain(e.to_string()))?;
			Ok((Listener::Onion(server), locator))
		}
		_ => unreachable!("the tcp and relay families were handled above"),
	}
}

/// Open one register socket to prove the relay answers, then close it. The
/// host provider keeps registration retries in the background, so a
/// completed listen is not the evidence the relay exists. This is, and it
/// runs before the provider adopts the route.
async fn probe_register_endpoint(register: &str, designator: &str) -> Result<(), Refusal> {
	let url = format!("{register}?id={designator}");
	let connect = tokio_tungstenite::connect_async(&url);
	match tokio::time::timeout(RELAY_REGISTER_DEADLINE, connect).await {
		Ok(Ok((socket, _))) => {
			// The probe consumed nothing: dropping the socket ends it, and the
			// relay drops the registration with it.
			drop(socket);
			Ok(())
		}
		Ok(Err(_)) => Err(Refusal::unsupported(format!(
			"No relay answered a register socket at {register}."
		))),
		Err(_) => Err(Refusal::unsupported(
			"The relay did not answer a register socket in time.",
		)),
	}
}

/// The `list`, `up`, and `down` behavior published under the admin swiss.
pub(super) fn behavior(shared: Shared) -> impl FnMut(Option<&str>, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let verb = verb.ok_or("direct invocation is not supported")?;
		if super::carries_capability(args) {
			return Err(format!("listeners {verb} does not take capability arguments"));
		}
		match verb {
			LIST => {
				if !args.is_empty() {
					return Err("list takes no arguments".into());
				}
				Ok(rows(&shared))
			}
			UP => {
				let (transport, ask) = Ask::read(&rooms_glowcap::values(args).collect::<Vec<_>>())?;
				let state = shared.borrow();
				// The seat refuses in the turn what it can; the socket opens
				// outside it, because the driver refuses listener lifecycle
				// re-entering its active step.
				state.listeners.seats.admit(transport, &Env)?;
				let shared = shared.clone();
				state.operations.later(&state, "up", move |writer| {
					Box::pin(async move {
						up(&shared, &writer, transport, ask, true).await?;
						let state = shared.borrow();
						let seat = state.listeners.seats.seat(transport, &Env);
						Ok(listeners::row::<Wire>(&seat))
					})
				})
			}
			DOWN => {
				let id = listeners::read_down(&rooms_glowcap::values(args).collect::<Vec<_>>())?;
				let state = shared.borrow();
				state.listeners.seats.take_down(id)?;
				let shared = shared.clone();
				state.operations.later(&state, "down", move |writer| {
					Box::pin(async move {
						down(&shared, &writer, id).await?;
						Ok(Argument::Void)
					})
				})
			}
			_ => Err(format!("listeners has no method {verb}")),
		}
	}
}

fn rows(shared: &Shared) -> Argument {
	let state = shared.borrow();
	Argument::List(
		state
			.listeners
			.seats
			.seats(&Env)
			.iter()
			.map(listeners::row::<Wire>)
			.collect(),
	)
}

/// The seat rows in the binding's arguments.
struct Wire;
impl listeners::Wire for Wire {
	type Value = Argument;
	fn text(value: &str) -> Argument {
		Argument::String(value.into())
	}
	fn integer(value: u64) -> Argument {
		Argument::Integer(i64::try_from(value).unwrap_or(i64::MAX))
	}
	fn boolean(value: bool) -> Argument {
		Argument::Boolean(value)
	}
	fn null() -> Argument {
		Argument::Void
	}
	fn list(values: Vec<Argument>) -> Argument {
		Argument::List(values)
	}
}
