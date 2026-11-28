//! Stable identity of one posting grant and its exact room seat or direct route.
//! Coordinates can check an already held authority; they cannot recreate it.
use rooms_application::{content::session::workspace::Conversation, fields::lower_hex};
use rooms_services::session::attached::Snapshot;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Scope {
	kind: super::Kind,
	grant: String,
	conversation: String,
	target: String,
}

impl Scope {
	pub fn holds_grant(&self, grant: &str) -> bool {
		self.grant == grant
	}
	pub fn valid(&self) -> bool {
		let digest = |s: &str| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit());
		self.kind != super::Kind::Other && digest(&self.target) && digest(&self.grant)
	}

	pub fn storage_fingerprint(&self) -> String {
		let mut digest = Sha256::new();
		digest.update(self.grant.as_bytes());
		digest.update([0]);
		digest.update(self.target.as_bytes());
		digest.update([0]);
		digest.update(self.conversation.as_bytes());
		lower_hex(&digest.finalize())
	}

	pub fn kind(&self) -> super::Kind {
		self.kind
	}

	pub fn conversation(&self) -> &str {
		&self.conversation
	}

	pub fn matches(&self, grant: &str, snapshot: &Snapshot) -> bool {
		Self::held(grant, self.conversation(), snapshot).as_ref() == Some(self)
	}

	pub fn held(grant: &str, conversation: &str, view: &Snapshot) -> Option<Self> {
		Self::direct_or_room(grant, conversation, view, false)
	}

	/// An uninstalled first return route identifies a pending receiver. This
	/// comparison never authorizes a send. Only held() observes real custody.
	pub fn opening(grant: &str, conversation: &str, view: &Snapshot) -> Option<Self> {
		Self::direct_or_room(grant, conversation, view, true)
	}

	fn direct_or_room(grant: &str, conversation: &str, view: &Snapshot, opening: bool) -> Option<Self> {
		use rooms_application::content::session::workspace::{FIRST_RECIPROCAL, reciprocal_key};
		let row = view
			.intent
			.conversations
			.as_slice()
			.iter()
			.find(|row| row.id().text().as_str() == Some(conversation))?;
		let (kind, directory, target) = match row {
			Conversation::Room(_) if opening => return None,
			Conversation::Room(room) => (
				super::Kind::Room,
				&room.directory,
				json!([
					"room",
					room.source,
					room.inbox,
					room.access,
					room.accepted,
					room.public_entry,
					room.publication,
					room.seat?
				]),
			),
			Conversation::Direct(dm) => (super::Kind::Direct, &dm.directory, {
				let key = if opening {
					if dm.closed || dm.introduction.is_none() || dm.access.is_some() {
						return None;
					}
					reciprocal_key(dm.inbox?, FIRST_RECIPROCAL)
				} else {
					dm.installed_access()?
				};
				json!(["direct", dm.peer, dm.source, dm.introduction, key])
			}),
		};
		let directory = view
			.intent
			.directories
			.as_slice()
			.iter()
			.find(|row| &row.id == directory)?;
		let target = json!([directory.id, directory.access, directory.source, target]);
		Some(Self {
			kind,
			grant: grant.into(),
			conversation: conversation.into(),
			target: lower_hex(&Sha256::digest(target.to_string().as_bytes())),
		})
	}
}
