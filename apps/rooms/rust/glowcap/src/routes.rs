//! Rooms' stable peer authority over the binding's existing locator grammar.
use glowcap::{
	CaptpVersion, HintValue, HintWireForm, Locator, HINT_ALT_LOCATORS, HINT_VIA, TRANSPORT_ID, TRANSPORT_IROH,
	TRANSPORT_KEYED_RELAY, TRANSPORT_KEYED_TCP, TRANSPORT_NOISE_RELAY, TRANSPORT_NOISE_TCP, TRANSPORT_ONION,
	TRANSPORT_TCP,
};

pub mod joining;

/// Route inspection keeps the binding's detailed diagnostic off every success
/// stack frame. Invalid input is ordinary absence; exceptional ABI/resource
/// failures pay one allocation to retain that diagnostic intact.
pub type Result<T> = std::result::Result<T, Box<glowcap::Error>>;

pub struct CheckpointRoutes;

/// Application-facing address facts. Inspection uses the substrate's locator
/// parser without creating a Host; none of these strings conveys a live grant.
pub struct Address {
	pub authority: String,
	pub address: String,
	pub transport: String,
	pub designator: String,
}
impl Address {
	pub fn directory(value: &str) -> Result<Option<Self>> {
		let locator = if value.contains("://") {
			input(glowcap::parse_locator(value))?
		} else {
			input(glowcap::designator_host_port(value))?.map(|(host, port)| glowcap::tcp::locator(&host, port))
		};
		locator.map(Self::from_locator).transpose()
	}
	pub fn capability(value: &str) -> Result<Option<Self>> {
		let Some(link) = input(glowcap::parse_sturdyref(value, CaptpVersion::V1_0))? else {
			return Ok(None);
		};
		if link.swissnum.is_empty() {
			return Ok(None);
		}
		Self::from_locator(link.locator).map(Some)
	}
	pub fn from_locator(locator: Locator) -> Result<Self> {
		let authority = peer_uri(&locator)?;
		let address = if locator.transport == TRANSPORT_TCP {
			locator.designator.clone()
		} else {
			glowcap::format_locator_uri(&locator)?
		};
		Ok(Self {
			authority,
			address,
			transport: locator.transport,
			designator: locator.designator,
		})
	}
}
// Only a typed grammar refusal is ordinary invalid input. Resource and ABI
// failures must reach the caller rather than asking it to retry a valid address.
fn input<T>(result: glowcap::Result<T>) -> Result<Option<T>> {
	match result {
		Ok(value) => Ok(Some(value)),
		Err(error) if error.kind() == glowcap::ErrorKind::InvalidArgument => Ok(None),
		Err(error) => Err(Box::new(error)),
	}
}

fn address(locator: &Locator) -> Option<String> {
	if locator.transport == TRANSPORT_TCP {
		Some(locator.designator.clone())
	} else {
		glowcap::format_locator_uri(locator).ok()
	}
}

/// The transports that prove a Host's key, in the order a route names them.
const ROUTE_ORDER: [&str; 3] = [TRANSPORT_IROH, TRANSPORT_NOISE_RELAY, TRANSPORT_NOISE_TCP];
/// The weak fallbacks for peers that do not speak the route vocabulary.
const FALLBACK_ORDER: [&str; 4] = [
	TRANSPORT_ONION,
	TRANSPORT_TCP,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_KEYED_RELAY,
];

/// Compose the identity-first location a Rooms host may advertise from every
/// listener it holds. Key-proving listeners whose designator is the host key
/// establish the identity; baseline listeners remain weak fallbacks. One
/// proving route without added reachability stays a concrete locator, so
/// `None` says to advertise the caller's own listener.
pub fn identity_route(host_key: &str, locators: &[String]) -> Option<Locator> {
	let mut by_transport = std::collections::BTreeMap::new();
	for value in locators {
		let Some(route) = locator(value) else {
			continue;
		};
		let strong = ROUTE_ORDER.contains(&route.transport.as_str());
		let weak = FALLBACK_ORDER.contains(&route.transport.as_str());
		if !strong && !weak {
			continue;
		}
		if strong && route.designator != host_key {
			continue;
		}
		by_transport.insert(route.transport.clone(), route);
	}
	let uris = |order: &[&str]| -> Vec<String> {
		order
			.iter()
			.filter_map(|transport| by_transport.get(*transport))
			.filter_map(|route| glowcap::format_locator_uri(route).ok())
			.collect()
	};
	let routes = uris(&ROUTE_ORDER);
	let fallbacks = uris(&FALLBACK_ORDER);
	if routes.is_empty() || routes.len() + fallbacks.len() < 2 {
		return None;
	}
	let mut hints = std::collections::BTreeMap::new();
	hints.insert(HINT_VIA.to_string(), HintValue::String(routes.join("|")));
	if !fallbacks.is_empty() {
		hints.insert(HINT_ALT_LOCATORS.to_string(), HintValue::String(fallbacks.join("|")));
	}
	Some(Locator {
		transport: TRANSPORT_ID.to_string(),
		designator: host_key.to_string(),
		hints,
		hint_wire_form: HintWireForm::Map,
	})
}
/// Derive the offered room's directory and dialable locator from its bearer.
/// The carrying direct conversation supplies only the receiver nick and sender.
pub fn received_room_link(
	id: &str,
	nick: &str,
	label: &str,
	from: &str,
	link: &str,
) -> std::result::Result<
	rooms_application::session::checkpoint::invitations::RoomLink,
	rooms_application::session::checkpoint::commands::Error,
> {
	use rooms_application::session::checkpoint::{
		commands::Error,
		invitations::{RoomLink, RoomLinkInput},
	};
	let parsed = glowcap::parse_sturdyref(link, CaptpVersion::V1_0).map_err(|_| Error::Arguments)?;
	let directory = authority(&parsed.locator).ok_or(Error::Arguments)?;
	let locator = address(&parsed.locator).ok_or(Error::Arguments)?;
	RoomLink::new(
		RoomLinkInput {
			id,
			directory: &directory,
			locator: &locator,
			nick,
			label,
			from,
			link,
		},
		&CheckpointRoutes,
	)
}
/// Publication identity carried by a Rooms authority. Fatal UTF-8 decoding
/// matches the document contract, including stripping a leading BOM.
pub fn authority_token(value: &str) -> Result<Option<String>> {
	let Some(link) = input(glowcap::parse_sturdyref(value, CaptpVersion::V1_0))? else {
		return Ok(None);
	};
	let Ok(mut token) = String::from_utf8(link.swissnum) else {
		return Ok(None);
	};
	if token.starts_with('\u{feff}') {
		token.drain(..'\u{feff}'.len_utf8());
	}
	Ok((!token.is_empty()).then_some(token))
}
impl rooms_application::session::checkpoint::commands::CommandRoutes for CheckpointRoutes {
	fn authority_token(&self, value: &str) -> Option<String> {
		authority_token(value).ok().flatten()
	}
}

pub fn locator(value: &str) -> Option<Locator> {
	if value.contains("://") {
		return glowcap::parse_locator(value).ok();
	}
	let (host, port) = glowcap::designator_host_port(value).ok()?;
	Some(glowcap::tcp::locator(&host, port))
}
fn authority(locator: &Locator) -> Option<String> {
	peer_uri(locator).ok()
}
fn peer_uri(locator: &Locator) -> Result<String> {
	let transport = match locator.transport.as_str() {
		TRANSPORT_ID | TRANSPORT_IROH | TRANSPORT_NOISE_RELAY | TRANSPORT_NOISE_TCP => TRANSPORT_ID,
		other => other,
	};
	Ok(glowcap::format_peer_uri(
		transport,
		&locator.designator,
		&Default::default(),
	)?)
}
impl rooms_application::session::checkpoint::Routes for CheckpointRoutes {
	fn locator_authority(&self, value: &str) -> Option<String> {
		authority(&locator(value)?)
	}
	fn sturdyref_authority(&self, value: &str) -> Option<String> {
		let link = glowcap::parse_sturdyref(value, CaptpVersion::V1_0).ok()?;
		if link.swissnum.is_empty() {
			return None;
		}
		authority(&link.locator)
	}
}

#[cfg(test)]
mod tests {
	#[test]
	fn address_input_preserves_runtime_failures() {
		assert!(super::Address::directory("not an address").unwrap().is_none());
		assert!(super::Address::capability("not a capability").unwrap().is_none());
		let error = glowcap::Error::from(std::io::Error::other("fixture resource failure"));
		let kind = error.kind();
		let message = error.to_string();
		let retained = super::input::<()>(Err(error)).unwrap_err();
		assert_eq!(retained.kind(), kind);
		assert_eq!(retained.to_string(), message);
	}
}
