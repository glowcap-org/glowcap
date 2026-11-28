//! The conversations the bot keeps state for, and the one bound on that
//! state. A conversation the bot has heard from keeps a context ring. One it
//! has answered also keeps a working directory, a state directory per harness,
//! and a session per harness. At most [`MAX_CONVERSATIONS`] are kept. Past it,
//! the conversation heard from longest ago that has no open turn is let go:
//! its files are removed first, then its sessions, then its place here, so a
//! crash partway lets it go again on the next batch.
use super::{error::Error, harness_sessions::HarnessSessions, rooms::ConversationId, store::Store};
use std::collections::{BTreeMap, BTreeSet};

const FILE: &str = "conversations.json";
// The most conversations the bot keeps state for, as many as a workspace
// holds. Even at the widest conversation ids the document stays under the
// size the bot reads back.
pub use rooms_application::content::session::workspace::MAX_CONVERSATIONS;

/// Each kept conversation and when it was last heard from, counted in batches.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Conversations(BTreeMap<ConversationId, u64>);

impl Conversations {
	pub fn load(store: &Store) -> Result<Self, Error> {
		Ok(Self(store.read(FILE)?.unwrap_or_default()))
	}

	/// Note that every conversation in `heard` was heard from now, and let go
	/// of the ones the bound no longer holds, never one in `open`. Nothing is
	/// noted unless every conversation let go is gone.
	pub fn heard(
		&mut self,
		store: &Store,
		sessions: &mut HarnessSessions,
		open: &BTreeSet<ConversationId>,
		heard: &BTreeSet<ConversationId>,
	) -> Result<(), Error> {
		if heard.is_empty() {
			return Ok(());
		}
		let now = self.0.values().max().map_or(0, |last| last.saturating_add(1));
		let mut next = self.clone();
		for conversation in heard {
			next.0.insert(conversation.clone(), now);
		}
		let mut gone = Vec::new();
		while next.0.len() > MAX_CONVERSATIONS {
			let Some(oldest) = next
				.0
				.iter()
				.filter(|(conversation, _)| !open.contains(*conversation) && !heard.contains(*conversation))
				.min_by_key(|(_, last)| **last)
				.map(|(conversation, _)| conversation.clone())
			else {
				break;
			};
			next.0.remove(&oldest);
			gone.push(oldest);
		}
		for conversation in &gone {
			store.forget_conversation(conversation)?;
		}
		sessions.forget_all(store, &gone)?;
		store.write(FILE, &next.0)?;
		*self = next;
		Ok(())
	}

	#[cfg(test)]
	fn kept(&self, conversation: &ConversationId) -> bool {
		self.0.contains_key(conversation)
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::bot::{context, store::file_stem};
	use rooms_testing::scratch::Scratch;

	fn ids(names: &[String]) -> BTreeSet<ConversationId> {
		names.iter().map(ConversationId::new).collect()
	}

	#[test]
	fn past_the_bound_the_conversation_heard_from_longest_ago_is_let_go_with_all_its_state() {
		let dir = Scratch::create("bot-conversations");
		let store = Store::open(&dir).unwrap();
		let mut sessions = HarnessSessions::default();
		let mut kept = Conversations::default();
		let open = ids(&["c0".into()]);
		let memory = crate::bot::home::create(store.root()).unwrap().join("memory/c1.md");
		std::fs::write(&memory, "Saved while c1 was kept\n").unwrap();
		for n in 0..MAX_CONVERSATIONS + 2 {
			let name = format!("c{n}");
			let conversation = ConversationId::new(&name);
			kept.heard(&store, &mut sessions, &open, &ids(&[name])).unwrap();
			context::append(&store, conversation.as_str(), Vec::new()).unwrap();
			store.workdir(conversation.as_str()).unwrap();
			std::fs::create_dir_all(store.harness_state("pi", conversation.as_str())).unwrap();
			sessions.remember(&store, "pi", &conversation, "s").unwrap();
		}
		assert_eq!(kept.0.len(), MAX_CONVERSATIONS);
		// c0 has an open turn, so c1 and c2 went in its place.
		let (open_one, first, second, last) = (
			ConversationId::new("c0"),
			ConversationId::new("c1"),
			ConversationId::new("c2"),
			ConversationId::new(format!("c{}", MAX_CONVERSATIONS + 1)),
		);
		assert!(kept.kept(&open_one) && kept.kept(&last));
		for gone in [&first, &second] {
			assert!(!kept.kept(gone));
			assert_eq!(sessions.get("pi", gone), None);
			assert!(!store.root().join("work").join(file_stem(gone)).exists());
			assert!(!store.harness_state("pi", gone.as_str()).exists());
		}
		assert_eq!(sessions.get("pi", &open_one), Some("s"));
		assert!(store.root().join("work/c0").exists());
		let reloaded = Conversations::load(&store).unwrap();
		assert_eq!(reloaded, kept);
		assert_eq!(HarnessSessions::load(&store).unwrap().get("pi", &first), None);
		assert_eq!(
			std::fs::read_to_string(&memory).unwrap(),
			"Saved while c1 was kept\n",
			"letting a conversation go touched the home"
		);
	}

	#[test]
	fn a_conversation_heard_again_outlasts_older_ones() {
		let dir = Scratch::create("bot-conversations-again");
		let store = Store::open(&dir).unwrap();
		let mut sessions = HarnessSessions::default();
		let mut kept = Conversations::default();
		let none = BTreeSet::new();
		let all: Vec<String> = (0..MAX_CONVERSATIONS).map(|n| format!("c{n}")).collect();
		kept.heard(&store, &mut sessions, &none, &ids(&all)).unwrap();
		kept.heard(&store, &mut sessions, &none, &ids(&["c0".into()])).unwrap();
		kept.heard(&store, &mut sessions, &none, &ids(&["new".into()])).unwrap();
		assert!(kept.kept(&ConversationId::new("c0")));
		assert!(kept.kept(&ConversationId::new("new")));
		assert_eq!(kept.0.len(), MAX_CONVERSATIONS);
	}
}
