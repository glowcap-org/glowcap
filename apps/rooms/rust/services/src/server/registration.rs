//! `register`: reading the locator claim the binding can check, minting the
//! registration's identity and its name capability, and filing it.
use super::behavior::{Reply, Shared, capability, text};
use glowcap::{
	Argument, Locator, Ref, Session, TRANSPORT_ID, TRANSPORT_KEYED_RELAY, TRANSPORT_KEYED_TCP, TRANSPORT_NOISE_RELAY,
	TRANSPORT_NOISE_TCP, TRANSPORT_WEBRTC, current_session,
};
use rooms_application::{
	directory::registration::{Id, NicknameAllocation, VOUCHER},
	room::ArgumentView,
	server::directory::{Effects, NAME_VOUCHER_BYTES, Register},
};
use rooms_glowcap::Value;

/// What the binding says about a locator a connection claims as its own.
struct Claim {
	/// Whether the claim holds against a proved durable identity, or nothing
	/// could be checked. Only a keyed connection can be refused here.
	own: bool,
	/// The durable peer this connection proved, when it proved one.
	claimant: Option<String>,
	/// The member's Host key, when the locator's designator is that key.
	host_key: Option<String>,
	/// The claim as a locator, when it is an `ocapn://` URI. The server
	/// embeds it in every handoff it mints for this member's exports, so a
	/// redeemer dials the route the member registered (an identity route
	/// across WebRTC and the relay, say), not the one transport the
	/// member's hello names. Without one, handoffs name the hello.
	locator: Option<Locator>,
}

/// The transports whose designator is the peer's Host key. An identity
/// route's designator is the key each of its routes proves, so signaling
/// aimed at its WebRTC route finds the member. An iroh node id is iroh's own
/// key, and an address names a socket, so neither is.
fn names_host_key(transport: &str) -> bool {
	[
		TRANSPORT_ID,
		TRANSPORT_WEBRTC,
		TRANSPORT_KEYED_TCP,
		TRANSPORT_NOISE_TCP,
		TRANSPORT_KEYED_RELAY,
		TRANSPORT_NOISE_RELAY,
	]
	.contains(&transport)
}

/// Read `locator` against `session`. A durable identity the partner proved
/// must name the same designator the locator claims (ADR-0028). An address
/// designator names a socket a key does not determine, so an unproved
/// connection holds its own claim.
fn claim(session: &Session, locator: &str) -> Result<Claim, String> {
	let (designator, host_key, parsed) = if locator.contains("://") {
		let parsed =
			glowcap::parse_locator(locator).map_err(|_| "register locator must be hostname:port or an ocapn:// URI")?;
		let host_key = names_host_key(&parsed.transport).then(|| parsed.designator.clone());
		(parsed.designator.clone(), host_key, Some(parsed))
	} else {
		glowcap::designator_host_port(locator)
			.map_err(|_| "register locator must be hostname:port or an ocapn:// URI")?;
		(locator.to_owned(), None, None)
	};
	let identity = session
		.partner_identity()
		.ok()
		.filter(|identity| identity.durable_identity_authenticated() && !identity.designator.is_empty());
	let own = identity
		.as_ref()
		.is_none_or(|identity| identity.designator == designator);
	Ok(Claim {
		own,
		claimant: identity.map(|identity| identity.designator),
		host_key,
		locator: parsed,
	})
}

fn fresh_id(state: &super::state::State) -> Result<Id, String> {
	// The identity is drawn here, so a collision with a filed one is a
	// question the policy answers before anything is filed under it.
	for _ in 0..8 {
		let mut bytes = [0u8; 16];
		rooms_platform::entropy::fill(&mut bytes)
			.map_err(|e| format!("drawing a registration identity failed: {e}"))?;
		let id = Id::from_entropy(bytes);
		if !state.policy.registration_known(&id) {
			return Ok(id);
		}
	}
	Err("registration identities are exhausted".into())
}

pub(super) fn register(state: &Shared, connection: u64, args: &[Argument]) -> Reply {
	let (allocation, voucher) = match args.len() {
		3 => (NicknameAllocation::Exact, None),
		4 if args.get(3).and_then(Argument::as_str).is_some() => match args.get(3).and_then(Argument::as_str) {
			Some(mode) => match NicknameAllocation::parse(mode) {
				Some(mode) => (mode, None),
				None => return Err(register_shape()),
			},
			None => return Err(register_shape()),
		},
		4 => match args.get(3).and_then(Argument::as_bytes) {
			Some(bytes) if bytes.len() == NAME_VOUCHER_BYTES => {
				let mut voucher = [0u8; NAME_VOUCHER_BYTES];
				voucher.copy_from_slice(bytes);
				(NicknameAllocation::Exact, Some(voucher))
			}
			_ => return Err(register_shape()),
		},
		5 => {
			let Some(mode) = args
				.get(3)
				.and_then(Argument::as_str)
				.and_then(NicknameAllocation::parse)
			else {
				return Err(register_shape());
			};
			let Some(bytes) = args
				.get(4)
				.and_then(Argument::as_bytes)
				.filter(|bytes| bytes.len() == NAME_VOUCHER_BYTES)
			else {
				return Err(register_shape());
			};
			let mut voucher = [0u8; NAME_VOUCHER_BYTES];
			voucher.copy_from_slice(bytes);
			(mode, Some(voucher))
		}
		_ => return Err(register_shape()),
	};
	let (Some(nick), Some(locator), Some(inbox)) = (text(args, 0), text(args, 1), capability(args, 2)) else {
		return Err(register_shape());
	};
	if nick.is_empty() || locator.is_empty() || args.iter().skip(3).any(|arg| Value(arg).contains_capability()) {
		return Err(register_shape());
	}
	let session = current_session()
		.map_err(|e| e.to_string())?
		.ok_or("register is reachable only over a session")?;
	let Claim {
		own,
		claimant,
		host_key,
		locator: claimed,
	} = claim(&session, locator)?;
	let mut held = state.borrow_mut();
	let id = fresh_id(&held)?;
	// The listing and the handoffs the server mints for this member name one
	// locator. The Host takes the claim before anything is filed, so a claim
	// it cannot embed is refused with nothing committed. A claim naming
	// another peer never reaches the Host, because the directory refuses it.
	let previous = held
		.handoff_locator(connection)
		.ok_or("caller connection has ended")?
		.clone();
	if own {
		session
			.set_exporter_locator(claimed.as_ref())
			.map_err(|e| format!("the registered locator can't be used for handoffs: {e}"))?;
	}
	let request = Register {
		nick: nick.into(),
		allocation,
		locator: locator.into(),
		own_locator: own,
		host_key,
		inbox: inbox.clone(),
		voucher,
		claimant,
	};
	let (granted, name, effects) = match file(state, &mut held, &session, connection, &id, request) {
		Ok(filed) => filed,
		Err(refusal) => {
			if own && let Err(cause) = session.set_exporter_locator(previous.as_ref()) {
				held.report(super::notice::Notice::Trouble {
					source: "restoring a refused registration's handoff locator".into(),
					reason: cause.to_string(),
				});
			}
			return Err(refusal);
		}
	};
	held.apply(effects);
	if let Some(slot) = held.handoff_locator(connection) {
		*slot = claimed;
	}
	// Identity and exact custody have one commit and one reply. Notifications
	// remain discovery events; losing one cannot make acquisition uncertain.
	Ok(Argument::List(vec![granted.into(), id.as_str().into(), name.into()]))
}

/// Mint the name capability and file the registration, the directory's one
/// commit. A directory refusal files nothing.
fn file(
	state: &Shared,
	held: &mut super::state::State,
	session: &Session,
	connection: u64,
	id: &Id,
	request: Register<Ref>,
) -> Result<(String, Ref, Effects<u64, Ref>), String> {
	// The exact name capability mints reconnect vouchers while current and
	// retires only this registration. Retirement remains idempotent after
	// replacement; it never selects another holder by nickname or connection.
	let name = {
		let state = state.clone();
		let id = id.clone();
		session
			.spawn_owned(move |verb, args| {
				let verb = verb.ok_or("unknown name capability method")?;
				{
					use rooms_application::{admission::Class, protocol_data, signaling};
					let mut held = state.borrow_mut();
					let (caller, _) = super::rooms::caller(&mut held)?;
					let class = match verb {
						protocol_data::LEAVE | signaling::DONE | signaling::DECLINE => Class::Cleanup,
						signaling::OFFER_INBOX | signaling::OFFER | signaling::ANSWER | signaling::CANDIDATE => {
							Class::Signal
						}
						_ => Class::Read,
					};
					if class != Class::Cleanup {
						held.ingress(caller)?;
					}
					// Offer charges both caller and recipient at the signaling owner.
					if verb != signaling::OFFER {
						held.admit_work(caller, class, 1)?;
					}
				}
				if verb == rooms_application::signaling::CHECK {
					if !args.is_empty() {
						return Err("signalCheck takes no arguments".into());
					}
					state
						.borrow()
						.policy
						.registration_connection(&id)
						.map_err(|refusal| refusal.reason())?;
					return Ok(Argument::Void);
				}
				if matches!(
					verb,
					rooms_application::signaling::OFFER_INBOX
						| rooms_application::signaling::OFFER
						| rooms_application::signaling::ANSWER
						| rooms_application::signaling::CANDIDATE
						| rooms_application::signaling::DONE
						| rooms_application::signaling::DECLINE
				) {
					let original = state
						.borrow()
						.policy
						.registration_connection(&id)
						.map_err(|refusal| refusal.reason())?;
					return super::signaling::dispatch(&state, original, verb, args);
				}
				if args.iter().any(|arg| Value(arg).contains_capability()) {
					return Err(format!("name capability {verb} does not take capability arguments"));
				}
				if verb == rooms_application::protocol_data::LEAVE {
					if !args.is_empty() {
						return Err("leave takes no arguments".into());
					}
					let mut state = state.borrow_mut();
					let effects = state.policy.retire_registration(&id);
					state.apply(effects);
					return Ok(Argument::Void);
				}
				if verb != VOUCHER {
					return Err(format!("a name capability has no method {verb}"));
				}
				if !args.is_empty() {
					return Err("voucher takes no arguments".into());
				}
				let mut bytes = [0u8; NAME_VOUCHER_BYTES];
				rooms_platform::entropy::fill(&mut bytes).map_err(|e| format!("drawing a voucher failed: {e}"))?;
				state
					.borrow_mut()
					.policy
					.voucher(&id, bytes)
					.map_err(|refusal| refusal.reason())?;
				Ok(Argument::Bytes(bytes.to_vec()))
			})
			.map_err(|e| e.to_string())?
	};
	let now = held.now();
	let effects = held
		.policy
		.register(connection, request, id.clone(), now)
		.map_err(|refusal| refusal.reason())?;
	let granted = held
		.policy
		.registered_nick(connection)
		.ok_or("committed registration names no holder")?
		.to_owned();
	Ok((granted, name, effects))
}

fn register_shape() -> String {
	format!(
		"register needs a nickname base, locator, inbox capability, optional allocation mode, and optional {NAME_VOUCHER_BYTES}-byte voucher"
	)
}

#[cfg(test)]
mod tests {
	use super::names_host_key;

	#[test]
	fn a_keyed_locator_names_the_host_key_and_iroh_or_an_address_does_not() {
		for transport in [
			glowcap::TRANSPORT_ID,
			glowcap::TRANSPORT_WEBRTC,
			glowcap::TRANSPORT_KEYED_TCP,
			glowcap::TRANSPORT_NOISE_TCP,
			glowcap::TRANSPORT_KEYED_RELAY,
			glowcap::TRANSPORT_NOISE_RELAY,
		] {
			assert!(names_host_key(transport), "{transport}");
		}
		for transport in [
			glowcap::TRANSPORT_IROH,
			glowcap::TRANSPORT_TCP,
			glowcap::TRANSPORT_ONION,
		] {
			assert!(!names_host_key(transport), "{transport}");
		}
	}
}
