//! Registering one connection with an IRC server: the nick and SASL
//! vocabulary, and the state machine that runs CAP, AUTHENTICATE, and the
//! welcome for the shared feed and for a member's own connection alike. The
//! socket driver feeds it every message before registration and sends what
//! it answers; after the welcome the driver owns the conversation.
use super::protocol::{Message, encode};
use alloc::{
	format,
	string::{String, ToString},
	vec::Vec,
};

const SASL_ACCOUNT_BYTES: usize = 64;
const SASL_PASSWORD_BYTES: usize = 256;
const SASL_CHUNK: usize = 400;
const REALNAME_BYTES: usize = 300;

#[derive(Clone, PartialEq, Eq)]
pub struct SaslPlain {
	pub account: String,
	pub password: String,
}

impl core::fmt::Debug for SaslPlain {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str("SaslPlain { credentials: [redacted] }")
	}
}

fn nick_start(c: char) -> bool {
	c.is_ascii_alphabetic() || matches!(c, '[' | ']' | '\\' | '`' | '_' | '^' | '{' | '|' | '}')
}

pub fn validate_nick(nick: &str) -> Result<(), String> {
	let mut chars = nick.chars();
	let ok = match chars.next() {
		Some(first) if nick_start(first) => {
			nick.chars().count() <= 28 && chars.all(|c| nick_start(c) || c.is_ascii_digit() || c == '-')
		}
		_ => false,
	};
	if ok {
		Ok(())
	} else {
		Err("IRC nickname must be 1..28 ASCII nickname characters and begin with a letter or special".into())
	}
}

/// Admit the GECOS/real-name value that IRC publishes in WHOIS. Feed callers
/// use it to identify the bot and a reachable administrator; the wire encoder
/// remains the final authority on the complete 512-byte USER line.
pub fn validate_realname(realname: &str) -> Result<(), String> {
	if realname.is_empty()
		|| realname.len() > REALNAME_BYTES
		|| realname.bytes().any(|byte| matches!(byte, 0 | b'\r' | b'\n'))
	{
		return Err(format!(
			"IRC real name must be 1..{REALNAME_BYTES} UTF-8 bytes without NUL or a line break"
		));
	}
	Ok(())
}

/// An IRC-legal nick for a Rooms name that is not one, derived from the
/// name so the same person is the same nick every time.
pub fn projected_nick(name: &str) -> String {
	let mut hash: u32 = 0x811c_9dc5;
	for byte in name.bytes() {
		hash ^= u32::from(byte);
		hash = hash.wrapping_mul(0x0100_0193);
	}
	format!("rooms-{hash:08x}")
}

/// The nick a member wears on IRC by default: their Rooms name when IRC
/// accepts it, else one projected from it.
pub fn automatic_nick(nick: &str) -> String {
	match validate_nick(nick) {
		Ok(()) => nick.into(),
		Err(_) => projected_nick(nick),
	}
}

/// Why an observed nick is not the one the member chose, or `None` when
/// IRC only changed its case.
pub fn rename_refusal(requested: &str, observed: &str) -> Option<String> {
	if super::protocol::fold(requested) == super::protocol::fold(observed) {
		return None;
	}
	Some(format!(
		"IRC changed the chosen nick from <{requested}> to <{observed}>. That nick may require login to its registered account."
	))
}

pub fn validate_sasl_plain(credentials: &SaslPlain) -> Result<(), String> {
	let account = credentials.account.len();
	let password = credentials.password.len();
	if account == 0 || account > SASL_ACCOUNT_BYTES || credentials.account.contains('\0') {
		return Err(format!(
			"IRC SASL account must be 1..{SASL_ACCOUNT_BYTES} UTF-8 bytes without NUL"
		));
	}
	if password == 0 || password > SASL_PASSWORD_BYTES || credentials.password.contains('\0') {
		return Err(format!(
			"IRC SASL password must be 1..{SASL_PASSWORD_BYTES} UTF-8 bytes without NUL"
		));
	}
	Ok(())
}

fn base64(bytes: &[u8]) -> String {
	const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
	for chunk in bytes.chunks(3) {
		let word = (u32::from(chunk[0]) << 16)
			| (chunk.get(1).map_or(0, |b| u32::from(*b)) << 8)
			| chunk.get(2).map_or(0, |b| u32::from(*b));
		let symbols = [(word >> 18) & 63, (word >> 12) & 63, (word >> 6) & 63, word & 63];
		for (at, symbol) in symbols.into_iter().enumerate() {
			if at <= chunk.len() {
				out.push(ALPHABET[symbol as usize] as char);
			} else {
				out.push('=');
			}
		}
	}
	out
}

/// The SASL PLAIN payload: `\0account\0password`, base64.
pub fn sasl_plain_payload(credentials: &SaslPlain) -> Result<String, String> {
	validate_sasl_plain(credentials)?;
	let raw = format!("\0{}\0{}", credentials.account, credentials.password);
	Ok(base64(raw.as_bytes()))
}

/// The AUTHENTICATE lines carrying one payload, 400 characters at a time,
/// with the empty continuation a full last chunk requires.
pub fn sasl_lines(credentials: &SaslPlain) -> Result<Vec<Vec<u8>>, String> {
	let payload = sasl_plain_payload(credentials)?;
	let mut lines = Vec::new();
	let bytes = payload.as_bytes();
	for chunk in bytes.chunks(SASL_CHUNK) {
		let text = core::str::from_utf8(chunk).map_err(|e| e.to_string())?;
		lines.push(encode("AUTHENTICATE", &[text]).map_err(|e| e.to_string())?);
	}
	if bytes.len().is_multiple_of(SASL_CHUNK) {
		lines.push(encode("AUTHENTICATE", &["+"]).map_err(|e| e.to_string())?);
	}
	Ok(lines)
}

/// The connection's role determines bot-mode and nick-change policy. Both
/// roles require the same SASL negotiation and casemapping.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
	Feed,
	Member,
}

/// What one observed message changed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
	/// The welcome arrived; `nick` is the one the server granted.
	Registered { nick: String },
	/// Registration cannot complete; the connection is over.
	Failed(String),
}

/// The lines to send and what happened, for one observed message.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Step {
	pub send: Vec<Vec<u8>>,
	pub event: Option<Event>,
}

impl Step {
	fn sends(send: Vec<Vec<u8>>) -> Self {
		Self { send, event: None }
	}
	fn failed(reason: impl Into<String>) -> Self {
		Self {
			send: Vec::new(),
			event: Some(Event::Failed(reason.into())),
		}
	}
}

/// One connection's registration, from the first line to the welcome.
#[derive(Clone, Debug)]
pub struct Registration {
	role: Role,
	nick: String,
	current: String,
	realname: String,
	sasl: Option<SaslPlain>,
	registered: bool,
	sasl_advertised: bool,
	sasl_plain_advertised: bool,
	sasl_requested: bool,
	sasl_started: bool,
	sasl_payload_sent: bool,
	sasl_authenticated: bool,
	bot_mode_requested: bool,
}

fn encoded(command: &str, params: &[&str]) -> Result<Vec<u8>, String> {
	encode(command, params).map_err(|e| e.to_string())
}

impl Registration {
	pub fn new(role: Role, nick: &str, realname: &str, sasl: Option<SaslPlain>) -> Result<Self, String> {
		validate_nick(nick)?;
		validate_realname(realname)?;
		if let Some(sasl) = &sasl {
			validate_sasl_plain(sasl)?;
		}
		Ok(Self {
			role,
			nick: nick.into(),
			current: nick.into(),
			realname: realname.into(),
			sasl_authenticated: sasl.is_none(),
			sasl,
			registered: false,
			sasl_advertised: false,
			sasl_plain_advertised: false,
			sasl_requested: false,
			sasl_started: false,
			sasl_payload_sent: false,
			bot_mode_requested: false,
		})
	}
	pub fn nick(&self) -> &str {
		&self.nick
	}
	/// The nick the connection wears now: the requested one until the
	/// server says otherwise.
	pub fn current(&self) -> &str {
		&self.current
	}
	pub fn registered(&self) -> bool {
		self.registered
	}
	/// The opening lines: capability negotiation when a login rides the
	/// connection, then NICK and USER.
	pub fn start(&self) -> Result<Vec<Vec<u8>>, String> {
		let mut lines = Vec::new();
		if self.sasl.is_some() {
			lines.push(encoded("CAP", &["LS", "302"])?);
		}
		lines.push(encoded("NICK", &[&self.nick])?);
		lines.push(encoded("USER", &[&self.nick, "0", "*", &self.realname])?);
		Ok(lines)
	}
	/// A PING answered at any time, registration or not.
	pub fn pong(message: &Message) -> Option<Vec<u8>> {
		if !message.is("PING") {
			return None;
		}
		let params: Vec<&str> = message.params.iter().map(String::as_str).collect();
		encode("PONG", &params).ok()
	}
	/// One message before the welcome. The driver sends `send` in order and
	/// acts on the event; a step with neither is a message to pass over.
	pub fn observe(&mut self, message: &Message) -> Step {
		if let Some(pong) = Self::pong(message) {
			return Step::sends(alloc::vec![pong]);
		}
		let step = self.observe_inner(message);
		match step {
			Ok(step) => step,
			Err(reason) => Step::failed(reason),
		}
	}
	fn observe_inner(&mut self, message: &Message) -> Result<Step, String> {
		let command = message.command.as_str();
		if self.registered && command == "CAP" {
			return Ok(Step::default());
		}
		if self.registered && command == "AUTHENTICATE" {
			return Err("IRC requested authentication after registration".into());
		}
		if command == "NICK" {
			if let (Some(next), true) = (message.param(0), self.is_self(message.prefix.as_deref())) {
				if self.role == Role::Feed
					&& let Some(reason) = rename_refusal(&self.nick, next)
				{
					return Err(reason);
				}
				self.current = next.into();
			}
			return Ok(Step::default());
		}
		// IRCv3 makes the mode letter server-owned through the BOT ISUPPORT
		// token. A feed marks itself when that token appears instead of assuming
		// the conventional +B or asking an operator to know server vocabulary.
		if command == "005" && self.role == Role::Feed && !self.bot_mode_requested {
			let mode = message.params.iter().find_map(|param| {
				param
					.strip_prefix("BOT=")
					.filter(|value| value.len() == 1 && value.as_bytes()[0].is_ascii_alphabetic())
			});
			if let Some(mode) = mode {
				self.bot_mode_requested = true;
				let setting = format!("+{mode}");
				return Ok(Step::sends(alloc::vec![encoded("MODE", &[&self.current, &setting],)?]));
			}
		}
		if command == "CAP" && self.sasl.is_some() {
			let subcommand = message.param(1).map(str::to_ascii_uppercase);
			let capabilities: Vec<&str> = message
				.last()
				.map(|s| s.split_whitespace().collect())
				.unwrap_or_default();
			match subcommand.as_deref() {
				Some("LS") => {
					for capability in &capabilities {
						let (name, mechanisms) = match capability.split_once('=') {
							Some((name, mechanisms)) => (name, Some(mechanisms)),
							None => (*capability, None),
						};
						if name != "sasl" {
							continue;
						}
						self.sasl_advertised = true;
						self.sasl_plain_advertised |= mechanisms.is_none_or(|list| {
							list.split(',').any(|mechanism| mechanism.eq_ignore_ascii_case("PLAIN"))
						});
					}
					let continued = message.param(2) == Some("*");
					if continued {
						return Ok(Step::default());
					}
					if !self.sasl_advertised {
						return Err("IRC server does not advertise SASL".into());
					}
					if !self.sasl_plain_advertised {
						return Err("IRC server does not advertise the SASL PLAIN mechanism".into());
					}
					self.sasl_requested = true;
					return Ok(Step::sends(alloc::vec![encoded("CAP", &["REQ", "sasl"])?]));
				}
				Some("ACK") => {
					let acked = capabilities
						.iter()
						.any(|capability| capability.split('=').next() == Some("sasl"));
					if acked && self.sasl_requested {
						self.sasl_started = true;
						return Ok(Step::sends(alloc::vec![encoded("AUTHENTICATE", &["PLAIN"])?]));
					}
				}
				Some("NAK") => return Err("IRC server refused the SASL capability".into()),
				_ => {}
			}
		}
		if command == "AUTHENTICATE" {
			if let (Some(sasl), Some("+")) = (&self.sasl, message.param(0)) {
				{
					if !self.sasl_started {
						return Err("IRC server started SASL before agreeing to it".into());
					}
					if self.sasl_payload_sent {
						return Err("IRC server requested the SASL payload twice".into());
					}
				}
				self.sasl_payload_sent = true;
				return Ok(Step::sends(sasl_lines(sasl)?));
			}
			if message.param(0) == Some("*") {
				return Err("IRC server aborted SASL authentication".into());
			}
		}
		if command == "903" && self.sasl.is_some() {
			if !self.sasl_payload_sent {
				return Err("IRC server completed SASL before receiving credentials".into());
			}
			self.sasl_authenticated = true;
			return Ok(Step::sends(alloc::vec![encoded("CAP", &["END"])?]));
		}
		if matches!(command, "902" | "904" | "905" | "906" | "907") {
			return Err(format!("IRC SASL authentication failed ({command})"));
		}
		if command == "433" {
			return Err(format!("IRC nickname \"{}\" is already in use", self.nick));
		}
		if command == "005" {
			for param in &message.params {
				let upper = param.to_ascii_uppercase();
				if let Some(mapping) = upper.strip_prefix("CASEMAPPING=")
					&& !mapping.eq_ignore_ascii_case("rfc1459")
				{
					return Err(format!("IRC server uses unsupported {param}"));
				}
			}
		}
		if command == "ERROR" {
			return Err(format!(
				"IRC server closed: {}",
				message.last().unwrap_or("unknown reason")
			));
		}
		if command == "001" && !self.registered {
			if !self.sasl_authenticated {
				return Err("IRC registered before SASL authentication completed".into());
			}
			if self.role == Role::Feed
				&& let Some(reason) = message.param(0).and_then(|nick| rename_refusal(&self.nick, nick))
			{
				return Err(reason);
			}
			self.registered = true;
			self.sasl = None;
			if let Some(granted) = message.param(0)
				&& granted != "*"
				&& granted != self.current
			{
				self.current = granted.into();
			}
			return Ok(Step {
				send: Vec::new(),
				event: Some(Event::Registered {
					nick: self.current.clone(),
				}),
			});
		}
		Ok(Step::default())
	}
	/// Whether a prefix names this connection's own nick.
	pub fn is_self(&self, prefix: Option<&str>) -> bool {
		super::protocol::nick_from_prefix(prefix)
			.is_some_and(|nick| super::protocol::fold(nick) == super::protocol::fold(&self.current))
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::server::irc::protocol::parse_line;

	fn line(text: &str) -> Message {
		parse_line(text).unwrap()
	}

	#[test]
	fn nicks_are_validated_projected_and_compared() {
		assert!(validate_nick("alice").is_ok());
		assert!(validate_nick("[brackets]_").is_ok());
		assert!(validate_nick("1digit").is_err());
		assert!(validate_nick("").is_err());
		assert!(validate_nick(&"a".repeat(29)).is_err());
		assert_eq!(projected_nick("web alice"), "rooms-4f93a545");
		assert_eq!(automatic_nick("alice"), "alice");
		assert!(automatic_nick("web alice").starts_with("rooms-"));
		assert!(rename_refusal("Chosen", "cHOSEN").is_none());
		assert!(
			rename_refusal("Chosen", "Guest1234")
				.unwrap()
				.contains("registered account")
		);
	}

	#[test]
	fn sasl_credentials_are_bounded_and_encoded() {
		let credentials = SaslPlain {
			account: "acct".into(),
			password: "pw".into(),
		};
		assert_eq!(sasl_plain_payload(&credentials).unwrap(), "AGFjY3QAcHc=");
		assert!(
			validate_sasl_plain(&SaslPlain {
				account: "".into(),
				password: "pw".into()
			})
			.is_err()
		);
		assert!(
			validate_sasl_plain(&SaslPlain {
				account: "a".into(),
				password: "x".repeat(257)
			})
			.is_err()
		);
		let lines = sasl_lines(&credentials).unwrap();
		assert_eq!(lines, [b"AUTHENTICATE AGFjY3QAcHc=\r\n".to_vec()]);
	}

	#[test]
	fn both_roles_register_with_sasl_and_refuse_a_missing_mechanism() {
		for role in [Role::Feed, Role::Member] {
			let sasl = SaslPlain {
				account: "acct".into(),
				password: "pw".into(),
			};
			let mut registration = Registration::new(role, "gwbot", "test identity", Some(sasl)).unwrap();
			let start = registration.start().unwrap();
			assert_eq!(start[0], b"CAP LS 302\r\n");
			assert_eq!(start[1], b"NICK gwbot\r\n");
			let step = registration.observe(&line(":s CAP * LS :sasl=PLAIN,EXTERNAL"));
			assert_eq!(step.send, [b"CAP REQ sasl\r\n".to_vec()]);
			let step = registration.observe(&line(":s CAP * ACK :sasl"));
			assert_eq!(step.send, [b"AUTHENTICATE PLAIN\r\n".to_vec()]);
			let step = registration.observe(&line("AUTHENTICATE +"));
			assert_eq!(step.send.len(), 1);
			let step = registration.observe(&line(":s 903 gwbot :ok"));
			assert_eq!(step.send, [b"CAP END\r\n".to_vec()]);
			let step = registration.observe(&line(":s 001 gwbot :welcome"));
			assert_eq!(step.event, Some(Event::Registered { nick: "gwbot".into() }));
			let mut strict = Registration::new(
				role,
				"gwbot",
				"test identity",
				Some(SaslPlain {
					account: "a".into(),
					password: "b".into(),
				}),
			)
			.unwrap();
			let step = strict.observe(&line(":s CAP * LS :sasl=EXTERNAL"));
			assert!(matches!(step.event, Some(Event::Failed(reason)) if reason.contains("PLAIN")));
		}
	}

	#[test]
	fn a_feed_refuses_a_different_registration_name_before_becoming_ready() {
		let mut registration = Registration::new(Role::Feed, "bridgebot", "bridge bot; admin: alice", None).unwrap();
		let step = registration.observe(&line(":s 001 Guest123 :welcome"));
		assert!(matches!(step.event, Some(Event::Failed(_))));
		assert!(!registration.registered());
		let step = registration.observe(&line(":s 001 BRIDGEBOT :welcome"));
		assert_eq!(
			step.event,
			Some(Event::Registered {
				nick: "BRIDGEBOT".into()
			})
		);
	}

	#[test]
	fn a_feed_publishes_its_operator_identity_and_uses_the_advertised_bot_mode() {
		assert!(Registration::new(Role::Feed, "bridgebot", "", None).is_err());
		let mut registration =
			Registration::new(Role::Feed, "bridgebot", "Rooms bridge bot; admin: operator", None).unwrap();
		assert_eq!(
			registration.start().unwrap(),
			[
				b"NICK bridgebot\r\n".to_vec(),
				b"USER bridgebot 0 * :Rooms bridge bot; admin: operator\r\n".to_vec(),
			]
		);
		assert!(Registration::new(Role::Feed, "bridgebot", "line\nbreak", None).is_err());
		registration.observe(&line(":s 001 bridgebot :welcome"));
		let step = registration.observe(&line(":s 005 bridgebot BOT=b CASEMAPPING=rfc1459 :are supported"));
		assert_eq!(step.send, [b"MODE bridgebot +b\r\n".to_vec()]);
		assert!(
			registration
				.observe(&line(":s 005 bridgebot BOT=b :are supported"))
				.send
				.is_empty()
		);

		let mut member = Registration::new(Role::Member, "reader", "Rooms member", None).unwrap();
		member.observe(&line(":s 001 reader :welcome"));
		assert!(
			member
				.observe(&line(":s 005 reader BOT=B :are supported"))
				.send
				.is_empty()
		);
	}

	#[test]
	fn a_member_follows_its_own_nick_and_answers_pings() {
		let mut registration = Registration::new(Role::Member, "reader", "Rooms member", None).unwrap();
		assert_eq!(registration.start().unwrap().len(), 2);
		let step = registration.observe(&line("PING :token"));
		assert_eq!(step.send, [b"PONG token\r\n".to_vec()]);
		let step = registration.observe(&line(":s 001 Reader2 :welcome"));
		assert_eq!(step.event, Some(Event::Registered { nick: "Reader2".into() }));
		registration.observe(&line(":Reader2!u@h NICK :Guest1"));
		assert_eq!(registration.current(), "Guest1");
		let step = registration.observe(&line(":s 433 * reader :in use"));
		assert!(matches!(step.event, Some(Event::Failed(reason)) if reason.contains("already in use")));
	}
}
