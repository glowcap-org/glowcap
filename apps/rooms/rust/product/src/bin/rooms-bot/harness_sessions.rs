//! Which harness session continues each conversation, kept per harness so a
//! change of `--harness` never hands one harness another's session id. The
//! conversations it holds are the ones [`super::conversations`] keeps.
use super::{error::Error, rooms::ConversationId, store::Store};
use std::collections::BTreeMap;

const FILE: &str = "sessions.json";
/// The largest session map the bot writes or reads: every harness's session
/// for every kept conversation, at the widest conversation ids and session
/// ids. A test fills every bound to prove it.
const MAX_STORE_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone, serde::Serialize, serde::Deserialize)]
#[serde(untagged)]
enum Saved {
	Id(String),
	Private { id: String, scope: super::rooms::Scope },
}

#[derive(Clone, Default)]
pub struct HarnessSessions(BTreeMap<String, BTreeMap<ConversationId, Saved>>);

impl HarnessSessions {
	pub fn load(store: &Store) -> Result<Self, Error> {
		Ok(Self(store.read_bounded(FILE, MAX_STORE_BYTES)?.unwrap_or_default()))
	}

	pub fn get(&self, harness: &str, conversation: &ConversationId) -> Option<&str> {
		Some(match self.0.get(harness)?.get(conversation)? {
			Saved::Id(id) | Saved::Private { id, .. } => id,
		})
	}

	pub fn scope(&self, harness: &str, conversation: &ConversationId) -> Option<&super::rooms::Scope> {
		match self.0.get(harness)?.get(conversation)? {
			Saved::Private { scope, .. } => Some(scope),
			Saved::Id(_) => None,
		}
	}

	/// Write the changed map, and keep it only once the write succeeds. A map
	/// that would outgrow the size the bot reads back is refused before any
	/// write.
	fn commit(&mut self, store: &Store, change: impl FnOnce(&mut Self)) -> Result<(), Error> {
		let mut next = self.clone();
		change(&mut next);
		next.0.retain(|_, map| !map.is_empty());
		store.write_bounded(FILE, &next.0, MAX_STORE_BYTES)?;
		*self = next;
		Ok(())
	}

	/// Remember the session a turn ended with.
	#[cfg(test)]
	pub fn remember(
		&mut self,
		store: &Store,
		harness: &str,
		conversation: &ConversationId,
		session: &str,
	) -> Result<(), Error> {
		self.remember_scoped(store, harness, conversation, session, None)
	}

	pub fn remember_scoped(
		&mut self,
		store: &Store,
		harness: &str,
		conversation: &ConversationId,
		session: &str,
		scope: Option<&super::rooms::Scope>,
	) -> Result<(), Error> {
		if self.get(harness, conversation) == Some(session) && self.scope(harness, conversation) == scope {
			return Ok(());
		}
		self.commit(store, |next| {
			next.0.entry(harness.to_owned()).or_default().insert(
				conversation.clone(),
				match scope {
					Some(scope) => Saved::Private {
						id: session.into(),
						scope: scope.clone(),
					},
					None => Saved::Id(session.into()),
				},
			);
		})
	}

	/// Forget a session the harness can no longer continue.
	pub fn forget(&mut self, store: &Store, harness: &str, conversation: &ConversationId) -> Result<(), Error> {
		if self.get(harness, conversation).is_none() {
			return Ok(());
		}
		self.commit(store, |next| {
			if let Some(map) = next.0.get_mut(harness) {
				map.remove(conversation);
			}
		})
	}

	/// Forget every harness's session of each conversation in `gone`.
	pub fn forget_all(&mut self, store: &Store, gone: &[ConversationId]) -> Result<(), Error> {
		let holds =
			|map: &BTreeMap<ConversationId, Saved>| gone.iter().any(|conversation| map.contains_key(conversation));
		if !self.0.values().any(holds) {
			return Ok(());
		}
		self.commit(store, |next| {
			for map in next.0.values_mut() {
				for conversation in gone {
					map.remove(conversation);
				}
			}
		})
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_testing::scratch::Scratch;

	#[test]
	fn sessions_are_kept_per_harness_and_survive_a_reload() {
		let dir = Scratch::create("bot-sessions");
		let store = Store::open(&dir).unwrap();
		let conversation = ConversationId::new("c1");
		let mut sessions = HarnessSessions::load(&store).unwrap();
		sessions.remember(&store, "claude", &conversation, "s1").unwrap();
		assert_eq!(sessions.get("codex", &conversation), None);
		let mut again = HarnessSessions::load(&store).unwrap();
		assert_eq!(again.get("claude", &conversation), Some("s1"));
		again.forget(&store, "claude", &conversation).unwrap();
		assert_eq!(
			HarnessSessions::load(&store).unwrap().get("claude", &conversation),
			None
		);
	}

	#[test]
	fn a_map_past_the_size_the_bot_reads_back_is_refused_before_any_write() {
		let dir = Scratch::create("bot-sessions-large");
		let store = Store::open(&dir).unwrap();
		let mut sessions = HarnessSessions::default();
		sessions
			.0
			.entry("claude".into())
			.or_default()
			.insert(ConversationId::new("c1"), Saved::Id("s".repeat(MAX_STORE_BYTES)));
		let result = sessions.remember(&store, "claude", &ConversationId::new("c2"), "s");
		assert!(matches!(
			result,
			Err(Error::TooLarge { ref file, .. }) if file == FILE
		));
		assert!(!dir.join("sessions.json").exists());
	}

	#[test]
	fn every_harness_at_every_kept_conversation_stays_under_the_size_it_reads_back() {
		use rooms_application::content::session::workspace::MAX_ID_UNITS;
		let mut sessions = HarnessSessions::default();
		for harness in crate::bot::harness::names() {
			let map = sessions.0.entry(harness.into()).or_default();
			for n in 0..crate::bot::conversations::MAX_CONVERSATIONS {
				let id = format!("{n:04}{}", "\u{1}".repeat(MAX_ID_UNITS - 4));
				map.insert(
					ConversationId::new(id.clone()),
					Saved::Private {
						id: "\"".repeat(crate::bot::runner::MAX_SESSION_ID_BYTES),
						scope: serde_json::from_value(serde_json::json!({
							"kind": "direct", "grant": "0".repeat(64),
							"conversation": id, "target":"f".repeat(64),
						}))
						.unwrap(),
					},
				);
			}
		}
		let bytes = crate::bot::store::encode(FILE, &sessions.0, MAX_STORE_BYTES)
			.unwrap()
			.len();
		assert!(bytes <= MAX_STORE_BYTES, "{bytes} bytes");
	}
}
