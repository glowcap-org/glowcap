//! The version-one operations document, `operations.json`: what an operator
//! asked this server to keep doing across restarts. The listener intents,
//! the IRC networks with their feed credentials, the channel bridges, and
//! each bridge generation's authority entropy are read as values, and a
//! document that fails its relations is refused rather than rewritten into
//! shape. It may hold a shared feed credential, so it stays under the
//! server's protected state directory and never enters snapshots.
use super::listeners::{Transport, MAX_OPTION_VALUE};
use crate::server::irc::model::{
	channel_key, entropy_hex, network_key, BridgeAuthority, BridgeIntent, NetworkChoice, ENTROPY_BYTES,
};
use alloc::{
	collections::{BTreeMap, BTreeSet},
	string::{String, ToString},
	vec::Vec,
};
use serde::{Deserialize, Serialize};

/// The most IRC rows of one kind the document keeps.
pub const MAX_IRC_ROWS: usize = super::MAX_OPERATIONS_ROWS;
const MAX_GENERATION: u64 = (1 << 53) - 1;

pub const FILE: &str = "operations.json";
pub const VERSION: u64 = 1;
pub const MAX_BYTES: usize = 2 * 1024 * 1024;
/// Listeners one server remembers.
pub const MAX_LISTENERS: usize = 8;
const MAX_OPTION_NAME: usize = 64;
const MAX_OPTIONS: usize = 16;

/// One listener the operator brought up and asked to keep.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ListenerIntent {
	pub transport: Transport,
	pub options: BTreeMap<String, OptionValue>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum OptionValue {
	Text(String),
	Number(u64),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Document {
	pub version: u64,
	pub listeners: Vec<ListenerIntent>,
	pub irc_networks: Vec<NetworkChoice>,
	pub irc_bridges: Vec<BridgeIntent>,
	pub irc_bridge_authorities: Vec<BridgeAuthority>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
	/// The bytes are not the JSON document this version reads.
	Json(String),
	/// The document parsed but its relations do not hold.
	Invalid(String),
	TooLarge,
}

impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::Json(_) => f.write_str("Rooms server operations state is not JSON"),
			Self::Invalid(detail) => write!(f, "Rooms server operations state is invalid:\n{detail}"),
			Self::TooLarge => f.write_str("Rooms server operations state is too large"),
		}
	}
}

impl Default for Document {
	fn default() -> Self {
		Self {
			version: VERSION,
			listeners: Vec::new(),
			irc_networks: Vec::new(),
			irc_bridges: Vec::new(),
			irc_bridge_authorities: Vec::new(),
		}
	}
}

impl Document {
	pub fn decode(text: &str) -> Result<Self, Error> {
		if text.len() > MAX_BYTES {
			return Err(Error::TooLarge);
		}
		let document: Self = serde_json::from_str(text).map_err(|e| Error::Json(e.to_string()))?;
		document.validate()?;
		Ok(document)
	}
	pub fn encode(&self) -> Result<String, Error> {
		let text = serde_json::to_string(self).map_err(|e| Error::Json(e.to_string()))?;
		if text.len() > MAX_BYTES {
			return Err(Error::TooLarge);
		}
		Ok(text)
	}
	pub fn validate(&self) -> Result<(), Error> {
		if self.version != VERSION {
			return Err(Error::Invalid(alloc::format!(
				"version {} is not {VERSION}",
				self.version
			)));
		}
		if self.listeners.len() > MAX_LISTENERS {
			return Err(Error::Invalid(alloc::format!(
				"at most {MAX_LISTENERS} listeners are kept"
			)));
		}
		let mut transports = BTreeSet::new();
		for intent in &self.listeners {
			if !transports.insert(intent.transport) {
				return Err(Error::Invalid(
					"listener transports, IRC channels, and bridge publication identities must be unique".into(),
				));
			}
			if intent.options.len() > MAX_OPTIONS {
				return Err(Error::Invalid("a listener keeps at most 16 options".into()));
			}
			for (name, value) in &intent.options {
				if name.is_empty() || name.len() > MAX_OPTION_NAME {
					return Err(Error::Invalid("a listener option name is 1 to 64 characters".into()));
				}
				if !intent.transport.options().contains(&name.as_str()) {
					return Err(Error::Invalid(alloc::format!(
						"a {} listener has no \"{name}\" option",
						intent.transport.name()
					)));
				}
				if let OptionValue::Text(text) = value {
					if text.len() > MAX_OPTION_VALUE {
						return Err(Error::Invalid("a listener option value is under 64 KiB".into()));
					}
				}
			}
		}
		self.validate_irc()
	}
	/// The IRC relations: one network per name, one bridge per channel
	/// under an open network, one publication id per bridge, and exactly
	/// one authority row per publication with entropy no other row shares.
	fn validate_irc(&self) -> Result<(), Error> {
		let unique = || {
			Error::Invalid("listener transports, IRC channels, and bridge publication identities must be unique".into())
		};
		if self.irc_networks.len() > MAX_IRC_ROWS
			|| self.irc_bridges.len() > MAX_IRC_ROWS
			|| self.irc_bridge_authorities.len() > MAX_IRC_ROWS
		{
			return Err(Error::Invalid(alloc::format!(
				"at most {MAX_IRC_ROWS} IRC rows of a kind are kept"
			)));
		}
		let mut networks = BTreeSet::new();
		for network in &self.irc_networks {
			network.validate().map_err(Error::Invalid)?;
			if !networks.insert(network.key()) {
				return Err(unique());
			}
		}
		let mut channels = BTreeSet::new();
		let mut publications = BTreeSet::new();
		for bridge in &self.irc_bridges {
			bridge.validate().map_err(Error::Invalid)?;
			if !networks.contains(&network_key(&bridge.network)) {
				return Err(Error::Invalid(alloc::format!(
					"the {}/{} bridge names a network the document does not keep",
					bridge.network,
					bridge.channel
				)));
			}
			if !channels.insert(bridge.key()) || !publications.insert(bridge.publication_id.clone()) {
				return Err(unique());
			}
		}
		let mut owned = BTreeSet::new();
		let mut entropy = BTreeSet::new();
		for authority in &self.irc_bridge_authorities {
			authority.validate().map_err(Error::Invalid)?;
			if !publications.contains(&authority.publication_id) || !owned.insert(authority.publication_id.clone()) {
				return Err(unique());
			}
			if !entropy.insert(authority.room_entropy.clone()) || !entropy.insert(authority.steward_entropy.clone()) {
				return Err(unique());
			}
		}
		if owned.len() != publications.len() {
			return Err(Error::Invalid(
				"every IRC bridge publication carries exactly one authority row".into(),
			));
		}
		Ok(())
	}
	pub fn irc_network(&self, name: &str) -> Option<&NetworkChoice> {
		let key = network_key(name);
		self.irc_networks.iter().find(|network| network.key() == key)
	}
	pub fn irc_bridge_authority(&self, publication_id: &str) -> Option<&BridgeAuthority> {
		self.irc_bridge_authorities
			.iter()
			.find(|row| row.publication_id == publication_id)
	}
	/// Keep one network. `false` when it is already kept exactly so.
	pub fn remember_irc_network(&mut self, choice: NetworkChoice) -> Result<bool, Error> {
		if let Some(existing) = self.irc_network(&choice.network) {
			if !existing.same(&choice) {
				return Err(Error::Invalid(alloc::format!(
					"IRC network {} already has different connection settings",
					choice.network
				)));
			}
			return Ok(false);
		}
		let mut next = self.clone();
		next.irc_networks.push(choice);
		next.validate()?;
		*self = next;
		Ok(true)
	}
	/// Forget one network with every bridge and authority beneath it.
	pub fn forget_irc_network(&mut self, name: &str) -> bool {
		let key = network_key(name);
		let before = self.irc_networks.len();
		self.irc_networks.retain(|network| network.key() != key);
		self.irc_bridges.retain(|bridge| network_key(&bridge.network) != key);
		self.prune_authorities();
		before != self.irc_networks.len()
	}
	/// Keep one bridge under its publication id, with fresh authority
	/// entropy drawn by `draw`. A bridge already kept under the same id is
	/// left as it is; one kept under another id is replaced whole, its old
	/// authority going with it.
	pub fn remember_irc_bridge(
		&mut self,
		intent: BridgeIntent,
		mut draw: impl FnMut() -> [u8; ENTROPY_BYTES],
	) -> Result<bool, Error> {
		let key = intent.key();
		if self
			.irc_bridges
			.iter()
			.any(|held| held.key() == key && held.publication_id == intent.publication_id)
		{
			return Ok(false);
		}
		let mut next = self.clone();
		if let Some(prior) = next.irc_bridges.iter().find(|held| held.key() == key).cloned() {
			next.irc_bridge_authorities
				.retain(|row| row.publication_id != prior.publication_id);
		}
		next.irc_bridges.retain(|held| held.key() != key);
		next.irc_bridge_authorities.push(BridgeAuthority {
			publication_id: intent.publication_id.clone(),
			room_entropy: entropy_hex(&draw()),
			steward_entropy: entropy_hex(&draw()),
			generation: 0,
			issued: false,
		});
		next.irc_bridges.push(intent);
		next.validate()?;
		*self = next;
		Ok(true)
	}
	pub fn forget_irc_bridge(&mut self, network: &str, channel: &str) -> bool {
		let key = channel_key(network, channel);
		let before = self.irc_bridges.len();
		self.irc_bridges.retain(|bridge| bridge.key() != key);
		self.prune_authorities();
		before != self.irc_bridges.len()
	}
	fn prune_authorities(&mut self) {
		let publications: BTreeSet<String> = self
			.irc_bridges
			.iter()
			.map(|bridge| bridge.publication_id.clone())
			.collect();
		self.irc_bridge_authorities
			.retain(|row| publications.contains(&row.publication_id));
	}
	/// Issue the moderator of one bridge generation: a fresh generation
	/// number over the same entropy. Answers the row as it stands, which is
	/// unchanged when it was already issued.
	pub fn issue_irc_bridge_steward(&mut self, publication_id: &str) -> Result<BridgeAuthority, Error> {
		let row = self
			.irc_bridge_authorities
			.iter_mut()
			.find(|row| row.publication_id == publication_id)
			.ok_or_else(|| Error::Invalid("that IRC bridge authority is not current".into()))?;
		if row.issued {
			return Ok(row.clone());
		}
		if row.generation >= MAX_GENERATION {
			return Err(Error::Invalid("IRC bridge moderator generation is exhausted".into()));
		}
		row.issued = true;
		row.generation += 1;
		Ok(row.clone())
	}
	/// Revoke the issued moderator: its entropy retires for fresh entropy
	/// from `draw`, so the old name answers nothing again.
	pub fn revoke_irc_bridge_steward(
		&mut self,
		publication_id: &str,
		steward_entropy: &str,
		draw: impl FnOnce() -> [u8; ENTROPY_BYTES],
	) -> Result<BridgeAuthority, Error> {
		let row = self
			.irc_bridge_authorities
			.iter_mut()
			.find(|row| row.publication_id == publication_id)
			.filter(|row| row.issued && row.steward_entropy == steward_entropy)
			.ok_or_else(|| Error::Invalid("that IRC bridge moderator capability is not current".into()))?;
		if row.generation >= MAX_GENERATION {
			return Err(Error::Invalid("IRC bridge moderator generation is exhausted".into()));
		}
		row.steward_entropy = entropy_hex(&draw());
		row.generation += 1;
		row.issued = false;
		Ok(row.clone())
	}
	pub fn listener(&self, transport: Transport) -> Option<&ListenerIntent> {
		self.listeners.iter().find(|intent| intent.transport == transport)
	}
	/// Keep `intent`, replacing the one for its transport. `false` when the
	/// document already says exactly this.
	pub fn remember_listener(&mut self, intent: ListenerIntent) -> Result<bool, Error> {
		if self.listener(intent.transport) == Some(&intent) {
			return Ok(false);
		}
		let mut next = self.clone();
		next.listeners.retain(|held| held.transport != intent.transport);
		next.listeners.push(intent);
		next.validate()?;
		*self = next;
		Ok(true)
	}
	pub fn forget_listener(&mut self, transport: Transport) -> bool {
		let before = self.listeners.len();
		self.listeners.retain(|held| held.transport != transport);
		before != self.listeners.len()
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_document_round_trips_and_replaces_one_intent_per_transport() {
		let mut document = Document::default();
		let mut options = BTreeMap::new();
		options.insert("port".to_string(), OptionValue::Number(1));
		assert!(document
			.remember_listener(ListenerIntent {
				transport: Transport::Tcp,
				options: options.clone(),
			})
			.unwrap());
		options.insert("port".to_string(), OptionValue::Number(2));
		assert!(document
			.remember_listener(ListenerIntent {
				transport: Transport::Tcp,
				options,
			})
			.unwrap());
		assert_eq!(document.listeners.len(), 1);
		let text = document.encode().unwrap();
		assert_eq!(Document::decode(&text).unwrap(), document);
		assert!(document.forget_listener(Transport::Tcp));
		assert!(!document.forget_listener(Transport::Tcp));
	}

	#[test]
	fn a_foreign_option_or_a_repeated_transport_is_refused_whole() {
		let text = r#"{"version":1,"listeners":[{"transport":"iroh","options":{"port":1}}],"ircNetworks":[],"ircBridges":[],"ircBridgeAuthorities":[]}"#;
		assert!(matches!(Document::decode(text), Err(Error::Invalid(_))));
		let text = r#"{"version":1,"listeners":[{"transport":"tcp","options":{}},{"transport":"tcp","options":{}}],"ircNetworks":[],"ircBridges":[],"ircBridgeAuthorities":[]}"#;
		assert!(matches!(Document::decode(text), Err(Error::Invalid(_))));
		assert!(matches!(Document::decode("nope"), Err(Error::Json(_))));
	}

	fn choice(name: &str) -> NetworkChoice {
		NetworkChoice {
			network: name.into(),
			host: "irc.example".into(),
			port: 6697,
			tls: true,
			nick: "feed".into(),
			sasl: None,
		}
	}

	#[test]
	fn the_irc_rows_are_kept_under_their_relations() {
		let mut document = Document::default();
		assert!(document.remember_irc_network(choice("Libera")).unwrap());
		assert!(!document.remember_irc_network(choice("libera")).unwrap());
		let mut other = choice("libera");
		other.port = 6667;
		assert!(document.remember_irc_network(other).is_err());
		let mut counter = 0u8;
		let mut draw = || {
			counter += 1;
			[counter; ENTROPY_BYTES]
		};
		let intent = BridgeIntent {
			network: "Libera".into(),
			channel: "#room".into(),
			publication_id: "p1".into(),
		};
		assert!(document.remember_irc_bridge(intent.clone(), &mut draw).unwrap());
		assert!(!document.remember_irc_bridge(intent.clone(), &mut draw).unwrap());
		let first = document.irc_bridge_authority("p1").unwrap().clone();
		assert!(!first.issued);
		let replaced = BridgeIntent {
			publication_id: "p2".into(),
			..intent.clone()
		};
		assert!(document.remember_irc_bridge(replaced, &mut draw).unwrap());
		assert!(document.irc_bridge_authority("p1").is_none());
		assert_eq!(document.irc_bridges.len(), 1);
		let text = document.encode().unwrap();
		assert!(text.contains("\"publicationId\":\"p2\""));
		assert_eq!(Document::decode(&text).unwrap(), document);
		let issued = document.issue_irc_bridge_steward("p2").unwrap();
		assert!(issued.issued && issued.generation == 1);
		assert_eq!(document.issue_irc_bridge_steward("p2").unwrap().generation, 1);
		assert!(document.revoke_irc_bridge_steward("p2", "wrong", &mut draw).is_err());
		let revoked = document
			.revoke_irc_bridge_steward("p2", &issued.steward_entropy, &mut draw)
			.unwrap();
		assert!(!revoked.issued && revoked.generation == 2 && revoked.steward_entropy != issued.steward_entropy);
		assert!(document.forget_irc_bridge("libera", "#ROOM"));
		assert!(document.irc_bridge_authorities.is_empty());
		document.remember_irc_bridge(intent, &mut draw).unwrap();
		assert!(document.forget_irc_network("libera"));
		assert!(document.irc_bridges.is_empty() && document.irc_bridge_authorities.is_empty());
	}

	#[test]
	fn broken_irc_relations_are_refused_whole() {
		let network = r#"{"network":"n","host":"h","port":6697,"tls":true,"nick":"f"}"#;
		let orphan = alloc::format!(
			r##"{{"version":1,"listeners":[],"ircNetworks":[{network}],"ircBridges":[{{"network":"other","channel":"#c","publicationId":"p"}}],"ircBridgeAuthorities":[]}}"##
		);
		assert!(matches!(Document::decode(&orphan), Err(Error::Invalid(_))));
		let unowned = alloc::format!(
			r##"{{"version":1,"listeners":[],"ircNetworks":[{network}],"ircBridges":[{{"network":"n","channel":"#c","publicationId":"p"}}],"ircBridgeAuthorities":[]}}"##
		);
		assert!(matches!(Document::decode(&unowned), Err(Error::Invalid(_))));
		let entropy = "0".repeat(32);
		let shared = alloc::format!(
			r##"{{"version":1,"listeners":[],"ircNetworks":[{network}],"ircBridges":[{{"network":"n","channel":"#c","publicationId":"p"}}],"ircBridgeAuthorities":[{{"publicationId":"p","roomEntropy":"{entropy}","stewardEntropy":"{entropy}","generation":0,"issued":false}}]}}"##
		);
		assert!(matches!(Document::decode(&shared), Err(Error::Invalid(_))));
		let whole = alloc::format!(
			r##"{{"version":1,"listeners":[],"ircNetworks":[{network}],"ircBridges":[{{"network":"n","channel":"#c","publicationId":"p"}}],"ircBridgeAuthorities":[{{"publicationId":"p","roomEntropy":"{entropy}","stewardEntropy":"{}","generation":0,"issued":false}}]}}"##,
			"1".repeat(32)
		);
		assert!(Document::decode(&whole).is_ok());
	}
}
