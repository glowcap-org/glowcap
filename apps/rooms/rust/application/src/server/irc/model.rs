//! The IRC gateway's own durable records: a network choice is IRC's
//! connection configuration, a bridge intent says one channel is bridged
//! under a publication identity, and a bridge authority is the entropy its
//! durable room and moderator names derive from. Each is written into
//! `operations.json` under the field names declared here, this crate's
//! version-one contract for that document.
use super::{
	protocol::fold,
	registration::{Invalid as RegistrationInvalid, SaslPlain, validate_realname},
};
use crate::fields::lower_hex;
use alloc::string::{String, ToString};
use serde::{Deserialize, Serialize};

/// The longest connection or lease name, shared with the gateway
/// description a snapshot carries.
pub use crate::bridge::gateway::MAX_NAME;
pub const MAX_PUBLICATION_ID: usize = 128;
/// A network must leave room for `/`, `#`, and at least one channel unit in
/// the 32-unit room name it will eventually prefix.
pub const MAX_NETWORK_NAME: usize = crate::server::rooms::MAX_ROOM - 3;
/// Bytes of entropy a durable bridge name derives from, as hex in the
/// document.
pub const ENTROPY_BYTES: usize = 16;
/// The fresh draws one bridge keeps when it is remembered: the room's and
/// the steward's, each the authority behind that side's capability.
#[derive(Clone, Copy, Debug)]
pub struct BridgeEntropy {
	pub room: [u8; ENTROPY_BYTES],
	pub steward: [u8; ENTROPY_BYTES],
}

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

/// Where a network is dialed, whether the leg is sealed, the feed's public
/// IRC identity, and its optional login.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NetworkChoice {
	pub network: String,
	pub host: String,
	pub port: u16,
	pub tls: bool,
	pub nick: String,
	pub realname: String,
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
			&& self.realname == other.realname
			&& self.sasl == other.sasl
	}
	pub fn endpoint(&self) -> String {
		alloc::format!("{}:{}", self.host, self.port)
	}
	/// Validate a connection that may become operational.
	pub fn validate(&self) -> Result<(), Invalid> {
		let bounded = |value: &str, what: &'static str| {
			if value.is_empty() || value.len() > 64 * 1024 {
				Err(Invalid::NetworkBytes { what })
			} else {
				Ok(())
			}
		};
		if self.network.is_empty() || self.network.encode_utf16().count() > MAX_NETWORK_NAME {
			return Err(Invalid::NetworkName);
		}
		bounded(&self.host, "host")?;
		bounded(&self.nick, "nick")?;
		validate_realname(&self.realname)?;
		if self.port == 0 {
			return Err(Invalid::NetworkPort);
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
	pub operator_permission: bool,
}

impl BridgeIntent {
	pub fn key(&self) -> String {
		channel_key(&self.network, &self.channel)
	}
	pub fn validate(&self) -> Result<(), Invalid> {
		if !self.operator_permission {
			return Err(Invalid::BridgePermission);
		}
		if self.network.is_empty() || self.network.encode_utf16().count() > MAX_NETWORK_NAME {
			return Err(Invalid::BridgeNetworkName);
		}
		if self.channel.is_empty() || self.channel.len() > 64 * 1024 {
			return Err(Invalid::BridgeChannel);
		}
		if alloc::format!("{}/{}", self.network, self.channel)
			.encode_utf16()
			.count() > crate::server::rooms::MAX_ROOM
		{
			return Err(Invalid::BridgedRoomName);
		}
		if self.publication_id.is_empty() || self.publication_id.len() > MAX_PUBLICATION_ID {
			return Err(Invalid::BridgePublicationId);
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
	lower_hex(bytes)
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
	pub fn validate(&self) -> Result<(), Invalid> {
		if self.publication_id.is_empty() || self.publication_id.len() > MAX_PUBLICATION_ID {
			return Err(Invalid::AuthorityPublicationId);
		}
		if !is_entropy(&self.room_entropy) || !is_entropy(&self.steward_entropy) {
			return Err(Invalid::AuthorityEntropy);
		}
		if self.generation > (1u64 << 53) - 1 {
			return Err(Invalid::ModeratorGeneration);
		}
		Ok(())
	}
}

/// Why a network choice, bridge intent, or bridge authority is refused.
/// `Display` is the exact line the operator reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Invalid {
	/// A network host, nick, account, or password is empty or over 64 KiB.
	NetworkBytes { what: &'static str },
	/// A network name is empty or too long for its bridged room names.
	NetworkName,
	/// The network's real name was refused.
	Realname(RegistrationInvalid),
	/// The network port is 0.
	NetworkPort,
	/// The bridge lacks the channel operators' permission.
	BridgePermission,
	/// The bridge's network name is empty or too long.
	BridgeNetworkName,
	/// The bridge's channel is empty or over 64 KiB.
	BridgeChannel,
	/// The bridged room name does not fit a room.
	BridgedRoomName,
	/// The bridge's publication id is empty or too long.
	BridgePublicationId,
	/// The authority's publication id is empty or too long.
	AuthorityPublicationId,
	/// The authority's entropy is not 16 bytes of hex.
	AuthorityEntropy,
	/// The authority's moderator generation is past the safe integer range.
	ModeratorGeneration,
}

impl core::fmt::Display for Invalid {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::NetworkBytes { what } => write!(f, "an IRC network {what} is 1 to 65536 bytes"),
			Self::NetworkName => write!(
				f,
				"an IRC network name is 1 to {MAX_NETWORK_NAME} characters so its bridged room names fit"
			),
			Self::Realname(source) => write!(f, "{source}"),
			Self::NetworkPort => f.write_str("an IRC network port is 1 through 65535"),
			Self::BridgePermission => {
				f.write_str("an IRC bridge requires explicit permission from the channel operators")
			}
			Self::BridgeNetworkName => write!(f, "an IRC bridge network name is 1 to {MAX_NETWORK_NAME} characters"),
			Self::BridgeChannel => f.write_str("an IRC bridge channel is 1 to 65536 bytes"),
			Self::BridgedRoomName => write!(
				f,
				"an IRC bridged room name is at most {} characters",
				crate::server::rooms::MAX_ROOM
			),
			Self::BridgePublicationId => f.write_str("an IRC bridge publication id is 1 to 128 bytes"),
			Self::AuthorityPublicationId => {
				f.write_str("an IRC bridge authority names a publication id of 1 to 128 bytes")
			}
			Self::AuthorityEntropy => f.write_str("an IRC bridge authority carries 16 bytes of entropy as hex"),
			Self::ModeratorGeneration => f.write_str("an IRC bridge moderator generation is a safe integer"),
		}
	}
}

impl core::error::Error for Invalid {}

impl From<Invalid> for String {
	fn from(invalid: Invalid) -> Self {
		invalid.to_string()
	}
}

impl From<RegistrationInvalid> for Invalid {
	fn from(source: RegistrationInvalid) -> Self {
		Self::Realname(source)
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn every_invalid_line_is_the_line_it_replaced() {
		let lines = [
			(
				Invalid::NetworkBytes { what: "host" },
				"an IRC network host is 1 to 65536 bytes",
			),
			(
				Invalid::NetworkName,
				"an IRC network name is 1 to 29 characters so its bridged room names fit",
			),
			(Invalid::NetworkPort, "an IRC network port is 1 through 65535"),
			(
				Invalid::BridgePermission,
				"an IRC bridge requires explicit permission from the channel operators",
			),
			(
				Invalid::BridgeNetworkName,
				"an IRC bridge network name is 1 to 29 characters",
			),
			(Invalid::BridgeChannel, "an IRC bridge channel is 1 to 65536 bytes"),
			(
				Invalid::BridgedRoomName,
				"an IRC bridged room name is at most 32 characters",
			),
			(
				Invalid::BridgePublicationId,
				"an IRC bridge publication id is 1 to 128 bytes",
			),
			(
				Invalid::AuthorityPublicationId,
				"an IRC bridge authority names a publication id of 1 to 128 bytes",
			),
			(
				Invalid::AuthorityEntropy,
				"an IRC bridge authority carries 16 bytes of entropy as hex",
			),
			(
				Invalid::ModeratorGeneration,
				"an IRC bridge moderator generation is a safe integer",
			),
			(
				Invalid::Realname(RegistrationInvalid::RealnameBytes),
				"IRC real name must be 1..300 UTF-8 bytes without NUL or a line break",
			),
		];
		for (invalid, line) in lines {
			assert_eq!(invalid.to_string(), line);
		}
	}

	#[test]
	fn a_choice_reads_and_writes_the_document_field_names() {
		let text = r#"{"network":"Libera","host":"irc.libera.chat","port":6697,"tls":true,"nick":"feed","realname":"bridge bot; admin: alice","sasl":{"account":"a","password":"b"}}"#;
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
		let bare: NetworkChoice = serde_json::from_str(
			r#"{"network":"n","host":"h","port":6667,"tls":false,"nick":"x","realname":"bridge bot; admin: alice"}"#,
		)
		.unwrap();
		assert!(bare.sasl.is_none());
		assert!(
			serde_json::from_str::<NetworkChoice>(r#"{"network":"n","host":"h","port":6667,"tls":false,"nick":"x"}"#)
				.is_err()
		);
		assert!(
			serde_json::from_str::<NetworkChoice>(
				r#"{"network":"n","host":"h","port":0,"tls":false,"nick":"x","realname":"bot; admin: alice","extra":1}"#
			)
			.is_err()
		);
	}

	#[test]
	fn entropy_round_trips_as_hex() {
		let bytes = [0x0fu8; ENTROPY_BYTES];
		let hex = entropy_hex(&bytes);
		assert_eq!(hex.len(), 32);
		assert_eq!(entropy_bytes(&hex), Some(bytes));
		assert!(entropy_bytes("zz").is_none());
		assert!(
			BridgeAuthority {
				publication_id: "p".into(),
				room_entropy: hex.clone(),
				steward_entropy: hex,
				generation: 0,
				issued: false,
			}
			.validate()
			.is_ok()
		);
	}

	#[test]
	fn network_and_channel_names_fit_the_room_they_construct() {
		let mut choice: NetworkChoice = serde_json::from_str(
			r#"{"network":"n","host":"h","port":6667,"tls":false,"nick":"x","realname":"bot; admin: alice"}"#,
		)
		.unwrap();
		choice.network = "n".repeat(MAX_NETWORK_NAME);
		assert!(choice.validate().is_ok());
		choice.network.push('n');
		assert!(choice.validate().is_err());

		let intent = BridgeIntent {
			network: "n".repeat(MAX_NETWORK_NAME),
			channel: "#x".into(),
			publication_id: "publication".into(),
			operator_permission: true,
		};
		assert!(intent.validate().is_ok());
		assert!(
			BridgeIntent {
				channel: "#xy".into(),
				..intent
			}
			.validate()
			.is_err()
		);
	}
}
