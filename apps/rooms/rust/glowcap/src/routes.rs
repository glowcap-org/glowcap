//! Rooms' stable peer authority over the binding's existing locator grammar.
use glowcap::{
	CaptpVersion, HINT_ALT_LOCATORS, HINT_VIA, HintValue, HintWireForm, Locator, TRANSPORT_ID, TRANSPORT_IROH,
	TRANSPORT_KEYED_RELAY, TRANSPORT_KEYED_TCP, TRANSPORT_NOISE_RELAY, TRANSPORT_NOISE_TCP, TRANSPORT_ONION,
	TRANSPORT_TCP, TRANSPORT_WEBRTC,
};

pub mod joining;

/// Route inspection keeps the binding's detailed diagnostic off every success
/// stack frame. Invalid input is ordinary absence. Exceptional ABI/resource
/// failures pay one allocation to retain that diagnostic intact.
pub type Result<T> = std::result::Result<T, Box<glowcap::Error>>;

/// Explicit acquisition of the public directory entry, or the exact supplied
/// capability. Formatting supplies a recipe only. The Host must still fetch it.
pub fn directory_recipe(route: &str) -> glowcap::Result<String> {
	match glowcap::parse_sturdyref(route, CaptpVersion::V1_0) {
		Ok(_) => return Ok(route.to_owned()),
		Err(error) if error.kind() == glowcap::ErrorKind::InvalidArgument => {}
		Err(error) => return Err(error),
	}
	let locator = directory_locator(route)?;
	glowcap::format_sturdyref(
		&locator,
		rooms_application::directory::NAME.as_bytes(),
		CaptpVersion::V1_0,
	)
}

fn directory_locator(value: &str) -> glowcap::Result<Locator> {
	if value.contains("://") {
		glowcap::parse_locator(value)
	} else {
		glowcap::designator_host_port(value).map(|(host, port)| glowcap::tcp::locator(&host, port))
	}
}

pub struct CheckpointRoutes;

/// Application-facing address facts. Inspection uses the substrate's locator
/// parser without creating a Host. None of these strings conveys a live grant.
pub struct Address {
	pub authority: String,
	pub address: String,
	pub transport: String,
	pub designator: String,
}
impl Address {
	pub fn directory(value: &str) -> Result<Option<Self>> {
		let locator = input(directory_locator(value))?;
		locator.map(Self::from_locator).transpose()
	}
	pub fn capability(value: &str) -> Result<Option<Self>> {
		capability_link(value)?
			.map(|link| Self::from_locator(link.locator))
			.transpose()
	}
	fn from_locator(locator: Locator) -> Result<Self> {
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
/// A Rooms v1.0 capability the text names, or `None` for text that is not one.
/// A link with no swiss number names an address, not a capability.
fn capability_link(value: &str) -> Result<Option<glowcap::SturdyRef>> {
	Ok(input(glowcap::parse_sturdyref(value, CaptpVersion::V1_0))?.filter(|link| !link.swissnum.is_empty()))
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

/// The transports that prove a Host's key, in the order a route names them.
const ROUTE_ORDER: [&str; 4] = [
	TRANSPORT_WEBRTC,
	TRANSPORT_IROH,
	TRANSPORT_NOISE_RELAY,
	TRANSPORT_NOISE_TCP,
];
/// The weak fallbacks for peers that do not speak the route vocabulary.
const FALLBACK_ORDER: [&str; 4] = [
	TRANSPORT_ONION,
	TRANSPORT_TCP,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_KEYED_RELAY,
];

/// Compose the identity-first location a Rooms host may advertise from every
/// listener it holds. Key-proving listeners whose designator is the host key
/// establish the identity. Baseline listeners remain weak fallbacks. One
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
/// The doors of a typed directory address, in the order a dial tries them,
/// or `None` for text that is not a directory address.
pub fn directory_doors(value: &str) -> Result<Option<Vec<Locator>>> {
	Ok(input(directory_locator(value))?.map(|location| doors(&location)))
}
/// The doors of a Rooms v1.0 capability's address, in the order a dial tries
/// them, or `None` for text that is not a capability.
pub fn capability_doors(value: &str) -> Result<Option<Vec<Locator>>> {
	Ok(capability_link(value)?.map(|link| doors(&link.locator)))
}
/// The concrete locators an advertised location names: the location itself,
/// or every `via` route and `alt-locators` door of an identity route. A
/// reader that must recognize its own addresses in a dial target reads this
/// instead of the route's transport.
pub fn doors(location: &Locator) -> Vec<Locator> {
	if location.transport != TRANSPORT_ID {
		return vec![location.clone()];
	}
	[HINT_VIA, HINT_ALT_LOCATORS]
		.iter()
		.filter_map(|hint| match location.hints.get(*hint) {
			Some(HintValue::String(list)) => Some(list),
			_ => None,
		})
		.flat_map(|list| list.split('|'))
		.filter_map(|uri| glowcap::parse_locator(uri).ok())
		.collect()
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
/// Every transport that proves the Host key names the same peer, so its
/// authority is the key's identity route. A weak fallback keeps its own.
fn peer_uri(locator: &Locator) -> Result<String> {
	let transport = match locator.transport.as_str() {
		strong if ROUTE_ORDER.contains(&strong) => TRANSPORT_ID,
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
	/// A browser's two doors both prove its key, so the Host races them.
	#[test]
	fn a_browser_races_webrtc_and_its_relay() {
		let key = "cd".repeat(32);
		let doors = [
			format!("ocapn://{key}.webrtc"),
			format!("ocapn://{key}.noise-relay?rendezvous-relay=ws%3A%2F%2F127.0.0.1%3A8080%2Frelay"),
		];
		let route = super::identity_route(&key, &doors).expect("two proving doors make a route");
		assert_eq!(route.transport, glowcap::TRANSPORT_ID);
		assert_eq!(
			route.hints.get(glowcap::HINT_VIA),
			Some(&glowcap::HintValue::String(doors.join("|")))
		);
		assert!(!route.hints.contains_key(glowcap::HINT_ALT_LOCATORS));
	}
	#[test]
	fn an_identity_route_opens_back_into_its_doors() {
		let key = "ab".repeat(32);
		let listeners = [
			"127.0.0.1:9000".to_owned(),
			format!("ocapn://{key}.noise-relay?rendezvous-relay=ws%3A%2F%2F127.0.0.1%3A8080%2Frelay"),
		];
		let route = super::identity_route(&key, &listeners).expect("two doors make a route");
		let doors = super::doors(&route);
		let transports: Vec<&str> = doors.iter().map(|door| door.transport.as_str()).collect();
		assert_eq!(transports, ["noise-relay", "tcp"]);
		assert_eq!(doors[1].designator, "127.0.0.1:9000");
		// A concrete location is its own one door.
		assert_eq!(super::doors(&doors[1]).len(), 1);
		// One listener is a concrete locator, not a route.
		assert!(super::identity_route(&key, &listeners[1..]).is_none());
		// A typed address opens into the same doors, and the shorthand is one TCP door.
		let typed = glowcap::format_locator_uri(&route).unwrap();
		assert_eq!(super::directory_doors(&typed).unwrap().unwrap().len(), 2);
		assert_eq!(
			super::directory_doors("127.0.0.1:9000").unwrap().unwrap()[0].transport,
			"tcp"
		);
		assert!(super::directory_doors("not an address").unwrap().is_none());
	}
	/// The route lists the host key's proving doors in dial order whatever
	/// order the listeners came in, and keeps a baseline door as a fallback.
	#[test]
	fn an_identity_route_orders_its_own_proving_doors_and_keeps_fallbacks_apart() {
		let key = "ab".repeat(32);
		let other = "cd".repeat(32);
		let route = super::identity_route(
			&key,
			&[
				format!("ocapn://{other}.iroh"),
				format!("ocapn://{key}.noise-tcp?direct-addresses=127.0.0.1%3A9000"),
				format!("ocapn://{key}.iroh"),
				"127.0.0.1:9000".to_owned(),
				format!("ocapn://{key}.noise-relay?rendezvous-relay=ws%3A%2F%2F127.0.0.1%3A8080%2Frelay"),
				format!("ocapn://{key}.webrtc"),
			],
		)
		.expect("proving doors and a fallback make a route");
		assert_eq!(route.designator, key);
		let doors = super::doors(&route);
		let transports: Vec<&str> = doors.iter().map(|door| door.transport.as_str()).collect();
		assert_eq!(transports, ["webrtc", "iroh", "noise-relay", "noise-tcp", "tcp"]);
		assert!(doors[..4].iter().all(|door| door.designator == key));
		let Some(glowcap::HintValue::String(fallbacks)) = route.hints.get(glowcap::HINT_ALT_LOCATORS) else {
			panic!("the baseline door is not a fallback");
		};
		assert!(!fallbacks.contains('|') && fallbacks.ends_with(".tcp"), "{fallbacks}");
	}
	/// A route needs one door that proves the host key and a second door of
	/// either kind. Another key's door and a baseline door prove nothing.
	#[test]
	fn an_identity_route_needs_a_proving_door_and_a_second_door() {
		let key = "ab".repeat(32);
		let other = "cd".repeat(32);
		let proving = format!("ocapn://{key}.iroh");
		let baseline = "127.0.0.1:9000".to_owned();
		let route = super::identity_route(&key, &[proving.clone(), baseline.clone()])
			.expect("a proving door and a baseline door make a route");
		let transports: Vec<String> = super::doors(&route).into_iter().map(|door| door.transport).collect();
		assert_eq!(transports, ["iroh", "tcp"]);
		assert!(super::identity_route(&key, std::slice::from_ref(&proving)).is_none());
		assert!(super::identity_route(&key, &[proving, format!("ocapn://{other}.noise-relay")]).is_none());
		assert!(super::identity_route(&key, &[baseline, format!("ocapn://{key}.keyed-tcp")]).is_none());
	}
	/// A browser on Browser to browser lists a bare WebRTC door, and on
	/// Fastest an identity route. Both name the one key's authority.
	#[test]
	fn every_key_proving_door_names_the_identity_authority() {
		let key = "ef".repeat(32);
		let identity = format!("ocapn://{key}.id");
		for transport in ["id", "webrtc", "iroh", "noise-relay", "noise-tcp"] {
			let address = super::Address::directory(&format!("ocapn://{key}.{transport}"))
				.unwrap()
				.unwrap();
			assert_eq!(address.authority, identity, "{transport}");
		}
		let weak = super::Address::directory(&format!("ocapn://{key}.keyed-tcp"))
			.unwrap()
			.unwrap();
		assert_eq!(weak.authority, format!("ocapn://{key}.keyed-tcp"));
	}
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
