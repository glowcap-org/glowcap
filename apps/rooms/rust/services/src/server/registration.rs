//! `register`: reading the locator claim the binding can check, minting the
//! registration's identity and its name capability, and filing it.
use super::behavior::{Reply, Shared, capability, text};
use glowcap::{Argument, Session, TRANSPORT_WEBRTC, current_session};
use rooms_application::{
	directory::registration::{Id, NicknameAllocation, VOUCHER},
	room::ArgumentView,
	server::directory::{NAME_VOUCHER_BYTES, Register},
};
use rooms_glowcap::Value;

/// What the binding says about a locator a connection claims as its own.
struct Claim {
	/// Whether the claim holds against a proved durable identity, or nothing
	/// could be checked. Only a keyed connection can be refused here.
	own: bool,
	/// The durable peer this connection proved, when it proved one.
	claimant: Option<String>,
	/// The `webrtc` designator the locator routes signaling by, if any.
	webrtc: Option<String>,
}

/// Read `locator` against `session`. A durable identity the partner proved
/// must name the same designator the locator claims (ADR-0097); an address
/// designator names a socket a key does not determine, so an unproved
/// connection holds its own claim.
fn claim(session: &Session, locator: &str) -> Result<Claim, String> {
	let (designator, webrtc) = if locator.contains("://") {
		let parsed =
			glowcap::parse_locator(locator).map_err(|_| "register locator must be hostname:port or an ocapn:// URI")?;
		let webrtc = (parsed.transport == TRANSPORT_WEBRTC).then(|| parsed.designator.clone());
		(parsed.designator, webrtc)
	} else {
		glowcap::designator_host_port(locator)
			.map_err(|_| "register locator must be hostname:port or an ocapn:// URI")?;
		(locator.to_owned(), None)
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
		webrtc,
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
	let claim = claim(&session, locator)?;
	let mut held = state.borrow_mut();
	let id = fresh_id(&held)?;
	// The name capability: the holding of this name, detached from the
	// connection that holds it. Its one verb mints a single-use voucher that
	// `register` on any connection redeems as being this member. It answers
	// only while this registration is the current one.
	let name = {
		let state = state.clone();
		let id = id.clone();
		session
			.spawn_owned(move |verb, args| {
				if args.iter().any(|arg| Value(arg).contains_capability()) {
					return Err(format!("name capability {verb} does not take capability arguments"));
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
		.register(
			connection,
			Register {
				nick: nick.into(),
				allocation,
				locator: locator.into(),
				own_locator: claim.own,
				webrtc: claim.webrtc,
				inbox: inbox.clone(),
				voucher,
				claimant: claim.claimant,
			},
			id,
			now,
		)
		.map_err(|refusal| refusal.reason())?;
	held.apply(effects);
	Ok(Argument::Reference(name))
}

fn register_shape() -> String {
	format!(
		"register needs a nickname base, locator, inbox capability, optional allocation mode, and optional {NAME_VOUCHER_BYTES}-byte voucher"
	)
}
