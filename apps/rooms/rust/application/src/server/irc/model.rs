//! The IRC gateway's own durable records: a network choice is IRC's
//! connection configuration, a bridge intent says one channel is bridged
//! under a publication identity, and a bridge authority is the entropy its
//! durable room and moderator names derive from. Each is written into
//! `operations.json` in the field names the TypeScript owner kept.
use super::{protocol::fold, registration::SaslPlain};
use alloc::string::String;
use serde::{Deserialize, Serialize};

/// The longest connection or lease name, shared with the gateway
/// description a snapshot carries.
pub use crate::bridge::gateway::MAX_NAME;
pub const MAX_PUBLICATION_ID: usize = 128;
/// Bytes of entropy a durable bridge name derives from, as hex in the
/// document.
pub const ENTROPY_BYTES: usize = 16;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Sasl {
	pub account: String,
	pub password: String,
}

impl core::fmt::Debug for Sasl {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str("Sasl { credentials: [redacted] }")
	}
}

impl From<&Sasl> for SaslPlain {
	fn from(sasl: &Sasl) -> Self {
		Self {
			account: sasl.account.clone(),
			password: sasl.password.clone(),
		}
	}
}

/// Where a network is dialed, whether the leg is sealed, the feed's nick,
/// and its optional login.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NetworkChoice {
	pub network: String,
	pub host: String,
	pub port: u16,
	pub tls: bool,
	pub nick: String,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	pub sasl: Option<Sasl>,
}

impl NetworkChoice {
	/// The key a network is held under: its name folded IRC's way.
	pub fn key(&self) -> String {
		network_key(&self.network)
	}
	/// Exact compatibility of two claims about one logical network.
	pub fn same(&self, other: &Self) -> bool {
		self.network.to_lowercase() == other.network.to_lowercase()
			&& self.host.to_lowercase() == other.host.to_lowercase()
			&& self.port == other.port
			&& self.tls == other.tls
			&& self.nick == other.nick
			&& self.sasl == other.sasl
	}
	pub fn endpoint(&self) -> String {
		alloc::format!("{}:{}", self.host, self.port)
	}
	/// What the document admits: every text bounded and non-empty, the
	/// port a port.
	pub fn validate(&self) -> Result<(), String> {
		let bounded = |value: &str, what: &str| {
			if value.is_empty() || value.len() > 64 * 1024 {
				Err(alloc::format!("an IRC network {what} is 1 to 65536 bytes"))
			} else {
				Ok(())
			}
		};
		bounded(&self.network, "name")?;
		bounded(&self.host, "host")?;
		bounded(&self.nick, "nick")?;
		if self.port == 0 {
			return Err("an IRC network port is 1 through 65535".into());
		}
		if let Some(sasl) = &self.sasl {
			bounded(&sasl.account, "account")?;
			bounded(&sasl.password, "password")?;
		}
		Ok(())
	}
}

pub fn network_key(network: &str) -> String {
	fold(network)
}

/// The key one bridged channel is held under: its network's key and the
/// channel folded, apart from each other.
pub fn channel_key(network: &str, channel: &str) -> String {
	alloc::format!("{}\0{}", network_key(network), fold(channel))
}

/// Durable server intent for one bridge. The publication id is correlation
/// identity, not bearer authority, and survives restoration.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct BridgeIntent {
	pub network: String,
	pub channel: String,
	pub publication_id: String,
}

impl BridgeIntent {
	pub fn key(&self) -> String {
		channel_key(&self.network, &self.channel)
	}
	pub fn validate(&self) -> Result<(), String> {
		if self.network.is_empty() || self.network.len() > 64 * 1024 {
			return Err("an IRC bridge network name is 1 to 65536 bytes".into());
		}
		if self.channel.is_empty() || self.channel.len() > 64 * 1024 {
			return Err("an IRC bridge channel is 1 to 65536 bytes".into());
		}
		if self.publication_id.is_empty() || self.publication_id.len() > MAX_PUBLICATION_ID {
			return Err("an IRC bridge publication id is 1 to 128 bytes".into());
		}
		Ok(())
	}
}

/// The durable entropy one bridge generation's room and moderator names
/// derive from, and whether the moderator is out.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct BridgeAuthority {
	pub publication_id: String,
	pub room_entropy: String,
	pub steward_entropy: String,
	pub generation: u64,
	pub issued: bool,
}

pub fn is_entropy(hex: &str) -> bool {
	hex.len() == ENTROPY_BYTES * 2 && hex.bytes().all(|b| b.is_ascii_digit() || matches!(b, b'a'..=b'f'))
}

pub fn entropy_hex(bytes: &[u8; ENTROPY_BYTES]) -> String {
	let mut out = String::with_capacity(ENTROPY_BYTES * 2);
	for byte in bytes {
		out.push_str(&alloc::format!("{byte:02x}"));
	}
	out
}

pub fn entropy_bytes(hex: &str) -> Option<[u8; ENTROPY_BYTES]> {
	if !is_entropy(hex) {
		return None;
	}
	let mut out = [0u8; ENTROPY_BYTES];
	for (at, byte) in out.iter_mut().enumerate() {
		*byte = u8::from_str_radix(&hex[at * 2..at * 2 + 2], 16).ok()?;
	}
	Some(out)
}

impl BridgeAuthority {
	pub fn validate(&self) -> Result<(), String> {
		if self.publication_id.is_empty() || self.publication_id.len() > MAX_PUBLICATION_ID {
			return Err("an IRC bridge authority names a publication id of 1 to 128 bytes".into());
		}
		if !is_entropy(&self.room_entropy) || !is_entropy(&self.steward_entropy) {
			return Err("an IRC bridge authority carries 16 bytes of entropy as hex".into());
		}
		if self.generation > (1u64 << 53) - 1 {
			return Err("an IRC bridge moderator generation is a safe integer".into());
		}
		Ok(())
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_choice_reads_and_writes_the_typescript_field_names() {
		let text = r#"{"network":"Libera","host":"irc.libera.chat","port":6697,"tls":true,"nick":"feed","sasl":{"account":"a","password":"b"}}"#;
		let choice: NetworkChoice = serde_json::from_str(text).unwrap();
		assert_eq!(serde_json::to_string(&choice).unwrap(), text);
		assert!(choice.validate().is_ok());
		let mut other = choice.clone();
		other.network = "LIBERA".into();
		assert!(choice.same(&other));
		other.tls = false;
		assert!(!choice.same(&other));
		assert_eq!(choice.key(), "libera");
		assert_eq!(channel_key("Libera", "#Room"), "libera\0#room");
		let bare: NetworkChoice =
			serde_json::from_str(r#"{"network":"n","host":"h","port":6667,"tls":false,"nick":"x"}"#).unwrap();
		assert!(bare.sasl.is_none());
		assert!(serde_json::from_str::<NetworkChoice>(
			r#"{"network":"n","host":"h","port":0,"tls":false,"nick":"x","extra":1}"#
		)
		.is_err());
	}

	#[test]
	fn entropy_round_trips_as_hex() {
		let bytes = [0x0fu8; ENTROPY_BYTES];
		let hex = entropy_hex(&bytes);
		assert_eq!(hex.len(), 32);
		assert_eq!(entropy_bytes(&hex), Some(bytes));
		assert!(entropy_bytes("zz").is_none());
		assert!(BridgeAuthority {
			publication_id: "p".into(),
			room_entropy: hex.clone(),
			steward_entropy: hex,
			generation: 0,
			issued: false,
		}
		.validate()
		.is_ok());
	}
}
