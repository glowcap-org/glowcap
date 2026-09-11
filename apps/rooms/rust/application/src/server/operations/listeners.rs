//! The listener seats an operator administers: one per transport this
//! server can realize, described in the owning package's own words, with
//! the options an `up` takes, the live listener in each seat, and the
//! refusals a seat gives before any socket is touched. The adapter brings
//! a listener up and down; this decides whether it may.
use super::document::{ListenerIntent, OptionValue};
use crate::{
	failure::FailureCode,
	room::{ArgumentView, ListArgument},
};
use alloc::{
	collections::BTreeMap,
	format,
	string::{String, ToString},
	vec::Vec,
};
use serde::{Deserialize, Serialize};

/// Live listeners one server holds at once. A resource bound, not an
/// authorization: whoever holds the capability may use all of it.
pub const MAX_LIVE: usize = 8;
/// A string option value, in bytes.
pub const MAX_OPTION_VALUE: usize = 64 * 1024;
const MAX_ASK_VALUE: usize = 4096;
const MAX_ASK_OPTIONS: usize = 8;
const MAX_TRANSPORT_NAME: usize = 16;
const MAX_ID: u64 = 1_000_000;

/// The transports a seat exists for, in the order `list` answers them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Transport {
	#[serde(rename = "tcp")]
	Tcp,
	#[serde(rename = "keyed-tcp")]
	KeyedTcp,
	#[serde(rename = "noise-tcp")]
	NoiseTcp,
	#[serde(rename = "iroh")]
	Iroh,
	#[serde(rename = "keyed-relay")]
	KeyedRelay,
	#[serde(rename = "noise-relay")]
	NoiseRelay,
	#[serde(rename = "onion")]
	Onion,
}

pub const TRANSPORTS: [Transport; 7] = [
	Transport::Tcp,
	Transport::KeyedTcp,
	Transport::NoiseTcp,
	Transport::Iroh,
	Transport::KeyedRelay,
	Transport::NoiseRelay,
	Transport::Onion,
];

/// One option an `up` takes: its name, the kind of value, and what a blank
/// field means.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Takes {
	pub name: &'static str,
	pub kind: &'static str,
	pub hint: &'static str,
}

const TCP_TAKES: &[Takes] = &[
	Takes {
		name: "bind",
		kind: "host",
		hint: "127.0.0.1",
	},
	Takes {
		name: "port",
		kind: "port",
		hint: "an ephemeral port",
	},
	Takes {
		name: "advertise",
		kind: "host",
		hint: "the bound address",
	},
];
const RELAY_TAKES: &[Takes] = &[Takes {
	name: "relay",
	kind: "url",
	hint: "",
}];

impl Transport {
	pub fn parse(name: &str) -> Option<Self> {
		TRANSPORTS.into_iter().find(|transport| transport.name() == name)
	}
	pub const fn name(self) -> &'static str {
		match self {
			Self::Tcp => "tcp",
			Self::KeyedTcp => "keyed-tcp",
			Self::NoiseTcp => "noise-tcp",
			Self::Iroh => "iroh",
			Self::KeyedRelay => "keyed-relay",
			Self::NoiseRelay => "noise-relay",
			Self::Onion => "onion",
		}
	}
	/// The package's own description of the profile.
	pub const fn summary(self) -> &'static str {
		match self {
			Self::Tcp => "Plain TCP, in the clear. For local development and peers that speak nothing else.",
			Self::KeyedTcp => "TCP dialed by key designator. Still in the clear: the key names a dial target and proves nobody.",
			Self::NoiseTcp => "TCP sealed end to end with Noise_XK. Finishing the handshake proves the peer's durable key.",
			Self::Iroh => "Encrypted QUIC. Peers dial the node id.",
			Self::KeyedRelay => "Held sockets registered at a WebSocket relay, in the clear. Somebody reaches this peer through the relay, so it opens no port of its own.",
			Self::NoiseRelay => "The same relay pipe with the Noise_XK seal over it. The relay forwards only ciphertext.",
			Self::Onion => "A Tor onion service, published through a running Tor.",
		}
	}
	/// Where a reader learns more, and what to call it.
	pub const fn reference(self) -> (&'static str, &'static str) {
		match self {
			Self::Tcp | Self::KeyedTcp | Self::KeyedRelay => ("", ""),
			Self::NoiseTcp | Self::NoiseRelay => ("https://noiseprotocol.org/", "Noise"),
			Self::Iroh => ("https://www.iroh.computer/", "iroh"),
			Self::Onion => ("https://community.torproject.org/onion-services/", "onion services"),
		}
	}
	pub const fn takes(self) -> &'static [Takes] {
		match self {
			Self::Tcp | Self::KeyedTcp | Self::NoiseTcp => TCP_TAKES,
			Self::KeyedRelay | Self::NoiseRelay => RELAY_TAKES,
			Self::Iroh | Self::Onion => &[],
		}
	}
	pub fn options(self) -> Vec<&'static str> {
		self.takes().iter().map(|takes| takes.name).collect()
	}
	pub const fn is_tcp_family(self) -> bool {
		matches!(self, Self::Tcp | Self::KeyedTcp | Self::NoiseTcp)
	}
	pub const fn is_relay_family(self) -> bool {
		matches!(self, Self::KeyedRelay | Self::NoiseRelay)
	}
}

/// Why a missing Tor stops an onion listener, the standing answer in `list`
/// and the refusal an `up` gives anyway.
pub const ONION_NEEDS_TOR: &str = "This server was started without a running Tor, so no onion listener can come up. GLOWCAP_ONION_SOCKS and GLOWCAP_ONION_CONTROL are not set.";

/// A refusal the caller hears as a break: a coded one a client acts on, or
/// text alone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
	pub code: Option<FailureCode>,
	pub detail: String,
}
impl Refusal {
	pub fn coded(code: FailureCode, detail: impl Into<String>) -> Self {
		Self {
			code: Some(code),
			detail: detail.into(),
		}
	}
	pub fn plain(detail: impl Into<String>) -> Self {
		Self {
			code: None,
			detail: detail.into(),
		}
	}
	pub fn unsupported(detail: impl Into<String>) -> Self {
		Self::coded(FailureCode::ListenerUnsupported, detail)
	}
	pub fn reason(&self) -> String {
		match self.code {
			Some(code) => format!("{}: {}", code.wire(), self.detail),
			None => self.detail.clone(),
		}
	}
}
impl From<Refusal> for String {
	fn from(refusal: Refusal) -> Self {
		refusal.reason()
	}
}

/// What an `up` asked for, read from the wire and checked against the
/// seat's declared options.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Ask {
	pub bind: Option<String>,
	pub port: Option<u16>,
	pub advertise: Option<String>,
	pub relay: Option<String>,
}

impl Ask {
	/// Read `up`'s arguments: the transport and, optionally, its named
	/// options as `[name, value]` pairs.
	pub fn read<A: ListArgument>(args: &[A]) -> Result<(Transport, Self), Refusal> {
		if args.is_empty() || args.len() > 2 {
			return Err(Refusal::plain(
				"up takes a transport and, optionally, its named options",
			));
		}
		let named = args[0]
			.text()
			.filter(|text| text.len() <= MAX_TRANSPORT_NAME)
			.ok_or_else(|| Refusal::plain("up takes the transport as a short string"))?;
		let transport = Transport::parse(named).ok_or_else(|| {
			Refusal::unsupported(format!(
				"\"{named}\" names no transport this server knows ({})",
				TRANSPORTS.map(Transport::name).join(", ")
			))
		})?;
		let mut ask = Self::default();
		let Some(options) = args.get(1) else {
			return Ok((transport, ask));
		};
		let count = options
			.list_len()
			.filter(|count| *count <= MAX_ASK_OPTIONS)
			.ok_or_else(|| Refusal::plain("up's options are a short list of [name, value] pairs"))?;
		let mut seen = Vec::new();
		for at in 0..count {
			let pair = options.at(at).filter(|pair| pair.list_len() == Some(2));
			let (Some(pair), Some(name)) = (pair.as_ref(), pair.as_ref().and_then(|pair| pair.at(0))) else {
				return Err(Refusal::plain("an up option is a [name, value] pair"));
			};
			let Some(name) = name.text() else {
				return Err(Refusal::plain("an up option is a [name, value] pair"));
			};
			if seen.contains(&name.to_string()) {
				return Err(Refusal::plain(format!("the {name} listener option was supplied twice")));
			}
			seen.push(name.to_string());
			let declared = transport.options();
			if !declared.contains(&name) {
				let takes = if declared.is_empty() {
					String::new()
				} else {
					format!(" (it takes {})", declared.join(", "))
				};
				return Err(Refusal::plain(format!(
					"a {} listener has no \"{name}\" option{takes}",
					transport.name()
				)));
			}
			let value = pair.at(1).expect("a pair has two elements");
			if name == "port" {
				let port = value
					.integer()
					.and_then(|port| u16::try_from(port).ok())
					.ok_or_else(|| Refusal::plain("port is an integer between 0 and 65535"))?;
				ask.port = Some(port);
				continue;
			}
			let text = value
				.text()
				.filter(|text| !text.is_empty() && text.len() <= MAX_ASK_VALUE)
				.ok_or_else(|| Refusal::plain(format!("{name} is a non-empty string under 4 KiB")))?;
			match name {
				"bind" => ask.bind = Some(text.into()),
				"advertise" => ask.advertise = Some(text.into()),
				"relay" => ask.relay = Some(text.into()),
				_ => unreachable!("the declared options are the four above"),
			}
		}
		Ok((transport, ask))
	}
	/// The intent kept for a listener brought up with this ask.
	pub fn intent(&self, transport: Transport) -> ListenerIntent {
		let mut options = BTreeMap::new();
		if let Some(bind) = &self.bind {
			options.insert("bind".into(), OptionValue::Text(bind.clone()));
		}
		if let Some(port) = self.port {
			options.insert("port".into(), OptionValue::Number(u64::from(port)));
		}
		if let Some(advertise) = &self.advertise {
			options.insert("advertise".into(), OptionValue::Text(advertise.clone()));
		}
		if let Some(relay) = &self.relay {
			options.insert("relay".into(), OptionValue::Text(relay.clone()));
		}
		ListenerIntent { transport, options }
	}
	/// The ask a kept intent replays.
	pub fn from_intent(intent: &ListenerIntent) -> Self {
		let text = |name: &str| match intent.options.get(name) {
			Some(OptionValue::Text(text)) => Some(text.clone()),
			_ => None,
		};
		Self {
			bind: text("bind"),
			port: match intent.options.get("port") {
				Some(OptionValue::Number(port)) => u16::try_from(*port).ok(),
				_ => None,
			},
			advertise: text("advertise"),
			relay: text("relay"),
		}
	}
}

/// `down`'s one argument: the listener's number.
pub fn read_down<A: ArgumentView>(args: &[A]) -> Result<u64, Refusal> {
	let [id] = args else {
		return Err(Refusal::plain("down takes the listener's number"));
	};
	id.integer()
		.and_then(|id| u64::try_from(id).ok())
		.filter(|id| (1..=MAX_ID).contains(id))
		.ok_or_else(|| Refusal::plain("down takes the number list answered"))
}

/// One live listener.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Live {
	pub id: u64,
	pub transport: Transport,
	pub locator: String,
	/// Whether the operator brought it up, so its intent is kept.
	pub managed: bool,
}

/// The seats and who sits in them. `announced` is the locator this server
/// printed: the listener carrying it never goes down through here.
#[derive(Default)]
pub struct Seats {
	rows: Vec<Live>,
	next: u64,
	announced: String,
}

/// What `list` says about one seat.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Seat {
	pub transport: Transport,
	pub takes: Vec<(String, String, String)>,
	pub unavailable: String,
	pub live: Option<Live>,
	pub serving: bool,
}

/// The environment a seat's hints and standing answers read.
pub trait Environment {
	fn env(&self, name: &str) -> Option<String>;
}

impl Seats {
	/// Adopt the boot listener, whose locator the server announced.
	pub fn adopt_boot(&mut self, transport: Transport, locator: String) -> u64 {
		self.announced = locator.clone();
		self.push(transport, locator, false)
	}
	fn push(&mut self, transport: Transport, locator: String, managed: bool) -> u64 {
		self.next += 1;
		let id = self.next;
		self.rows.push(Live {
			id,
			transport,
			locator,
			managed,
		});
		id
	}
	pub fn live(&self) -> impl Iterator<Item = &Live> {
		self.rows.iter()
	}
	pub fn held(&self, transport: Transport) -> Option<&Live> {
		self.rows.iter().find(|row| row.transport == transport)
	}
	pub fn announced(&self) -> &str {
		&self.announced
	}
	pub fn serving(&self, row: &Live) -> bool {
		row.locator == self.announced
	}
	/// Whether an `up` for `transport` may proceed to a socket.
	pub fn admit(&self, transport: Transport, env: &impl Environment) -> Result<(), Refusal> {
		if self.rows.len() >= MAX_LIVE {
			return Err(Refusal::plain(format!(
				"this server holds at most {MAX_LIVE} listeners at once"
			)));
		}
		if self.held(transport).is_some() {
			return Err(Refusal::coded(
				FailureCode::ListenerTransportHeld,
				format!(
					"This runtime holds one live listener per transport, and its {} listener is already up. Take that one down first.",
					transport.name()
				),
			));
		}
		if !unavailable(transport, env).is_empty() {
			return Err(Refusal::unsupported(ONION_NEEDS_TOR));
		}
		Ok(())
	}
	/// A listener came up.
	pub fn brought_up(&mut self, transport: Transport, locator: String, managed: bool) -> u64 {
		self.push(transport, locator, managed)
	}
	/// Whether `id` may go down, answering its row.
	pub fn take_down(&self, id: u64) -> Result<&Live, Refusal> {
		let row = self
			.rows
			.iter()
			.find(|row| row.id == id)
			.ok_or_else(|| Refusal::coded(FailureCode::NoSuchListener, format!("No listener is numbered {id}.")))?;
		if self.serving(row) {
			return Err(Refusal::coded(
				FailureCode::ListenerServing,
				format!("Listener {id} answers the locator this server announced. The web relay and this admin session ride it, so taking it down would cut them off."),
			));
		}
		Ok(row)
	}
	pub fn went_down(&mut self, id: u64) -> Option<Live> {
		let at = self.rows.iter().position(|row| row.id == id)?;
		Some(self.rows.remove(at))
	}
	/// Every row, for a shutdown that closes them all.
	pub fn drain(&mut self) -> Vec<Live> {
		self.announced.clear();
		core::mem::take(&mut self.rows)
	}
	pub fn seat(&self, transport: Transport, env: &impl Environment) -> Seat {
		let live = self.held(transport).cloned();
		Seat {
			transport,
			takes: transport
				.takes()
				.iter()
				.map(|takes| {
					let configured = match takes.name {
						"bind" => env.env("GLOWCAP_ROOMS_BIND"),
						"advertise" => env.env("GLOWCAP_ROOMS_ANNOUNCE_HOST"),
						"relay" => env.env("GLOWCAP_ROOMS_RELAY_URL"),
						_ => None,
					};
					(
						takes.name.into(),
						takes.kind.into(),
						configured.unwrap_or_else(|| takes.hint.into()),
					)
				})
				.collect(),
			unavailable: unavailable(transport, env),
			serving: live.as_ref().is_some_and(|live| self.serving(live)),
			live,
		}
	}
	pub fn seats(&self, env: &impl Environment) -> Vec<Seat> {
		TRANSPORTS
			.into_iter()
			.map(|transport| self.seat(transport, env))
			.collect()
	}
}

/// What this server can already tell would refuse an `up`, before one is
/// asked. Only cheaply knowable obstacles belong here.
pub fn unavailable(transport: Transport, env: &impl Environment) -> String {
	if transport != Transport::Onion {
		return String::new();
	}
	if env.env("GLOWCAP_ONION_SOCKS").is_some() && env.env("GLOWCAP_ONION_CONTROL").is_some() {
		return String::new();
	}
	ONION_NEEDS_TOR.into()
}

/// The register endpoint behind a relay URL: both first-party relays
/// register at `/register` beside whatever path dialers use.
pub fn register_url(relay_url: &str) -> Result<String, Refusal> {
	let (scheme, rest) = relay_url
		.split_once("://")
		.ok_or_else(|| Refusal::unsupported(format!("\"{relay_url}\" is not a WebSocket URL.")))?;
	if scheme != "ws" && scheme != "wss" {
		return Err(Refusal::unsupported(format!(
			"A relay URL uses ws or wss, and \"{relay_url}\" uses neither."
		)));
	}
	let authority = rest
		.split(['/', '?', '#'])
		.next()
		.filter(|authority| !authority.is_empty())
		.ok_or_else(|| Refusal::unsupported(format!("\"{relay_url}\" is not a WebSocket URL.")))?;
	Ok(format!("{scheme}://{authority}/register"))
}

/// The wire form of a seat row:
/// `[transport, summary, reference, referenceName, takes, unavailable, id, locator, serving]`.
pub trait Wire {
	type Value;
	fn text(value: &str) -> Self::Value;
	fn integer(value: u64) -> Self::Value;
	fn boolean(value: bool) -> Self::Value;
	fn null() -> Self::Value;
	fn list(values: Vec<Self::Value>) -> Self::Value;
}

pub fn row<W: Wire>(seat: &Seat) -> W::Value {
	let (reference, reference_name) = seat.transport.reference();
	W::list(alloc::vec![
		W::text(seat.transport.name()),
		W::text(seat.transport.summary()),
		W::text(reference),
		W::text(reference_name),
		W::list(
			seat.takes
				.iter()
				.map(|(name, kind, hint)| W::list(alloc::vec![W::text(name), W::text(kind), W::text(hint)]))
				.collect()
		),
		W::text(&seat.unavailable),
		W::integer(seat.live.as_ref().map_or(0, |live| live.id)),
		W::text(seat.live.as_ref().map_or("", |live| live.locator.as_str())),
		W::boolean(seat.serving),
	])
}

#[cfg(test)]
mod tests;
