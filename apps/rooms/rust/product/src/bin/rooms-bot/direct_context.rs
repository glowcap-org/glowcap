//! A private post made by a room turn can give a subsequent direct reply
//! its referent. Before dispatch retain only its operation, route and text
//! digest. Only a settled post supplies the text exposed to the recipient's
//! turn. One small table covers every conversation and survives a restart.
use super::{classify::Seq, context, error::Error, rooms::Scope, store};
use rooms_application::fields::lower_hex;
use rooms_platform::storage::{Directory, atomic};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{path::Path, time::Duration};

const DIR: &str = "direct-context";
const FILE: &str = "posts.json";
// A JSON control character takes six bytes. Each row holds at most one
// full conversation id, a clipped excerpt, the minted operation and hashes.
const MAX_BYTES: usize = 512 * 1024;

#[derive(Serialize, Deserialize)]
struct Post {
	operation: String,
	scope: Scope,
	digest: String,
	text: Option<String>,
	observed: Option<Seq>,
	claimed: Option<super::ledger::TurnId>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Speech {
	pub scope: Scope,
	pub text: String,
	pub operation: Option<String>,
}

impl Speech {
	pub fn bound(scope: Scope) -> Self {
		Self {
			scope,
			text: String::new(),
			operation: None,
		}
	}
}

pub fn present(root: &Path) -> bool {
	root.join(DIR).join(FILE).is_file()
}

fn digest(text: &str) -> String {
	lower_hex(&Sha256::digest(text.as_bytes()))
}

fn edit<T>(root: &Path, change: impl FnOnce(&mut Vec<Post>) -> (T, bool)) -> Result<T, Error> {
	let path = root.join(DIR);
	let lock = Directory::open_within(path.clone(), "lock", Duration::from_secs(1))?;
	let mut posts: Vec<Post> = store::read_unleased_bounded(&path, FILE, MAX_BYTES)?.unwrap_or_default();
	if posts.len() > context::MAX_LINES {
		return Err(Error::unreadable(FILE, "too many direct posts"));
	}
	let (result, changed) = change(&mut posts);
	if changed {
		let bytes = store::encode(FILE, &posts, MAX_BYTES)?;
		atomic::replace(&lock, FILE, [bytes.as_slice()])?;
	}
	Ok(result)
}

pub fn reserve(root: &Path, scope: Scope, operation: &str, text: &str) -> Result<(), Error> {
	edit(root, |posts| {
		if posts.len() == context::MAX_LINES {
			posts.remove(0);
		}
		posts.push(Post {
			operation: operation.into(),
			scope,
			digest: digest(text),
			text: None,
			observed: None,
			claimed: None,
		});
		((), true)
	})
}

/// The session publishes its sender event only after the post commits.
/// Its activity order proves the question preceded the incoming reply.
pub fn confirmed(root: &Path, scope: &Scope, operation: &str, text: &str, seq: Seq) -> Result<(), Error> {
	if !present(root) {
		return Ok(());
	}
	edit(root, |posts| {
		let Some(post) = posts.iter_mut().find(|p| p.operation == operation && &p.scope == scope) else {
			return ((), false);
		};
		if post.digest != digest(text) {
			return ((), false);
		}
		let new = post.observed.is_none();
		if new {
			let end = text.floor_char_boundary(context::MAX_TEXT_BYTES.min(text.len()));
			let mut kept = text.split_at(end).0.to_owned();
			if end < text.len() {
				kept.push_str(" [cut]");
			}
			post.text = Some(kept);
			post.observed = Some(seq);
		}
		((), new)
	})
}

pub fn latest(root: &Path, scope: &Scope, before: Seq, turn: super::ledger::TurnId) -> Result<Option<Speech>, Error> {
	if !present(root) {
		return Ok(None);
	}
	edit(root, |posts| {
		let speech = posts
			.iter()
			.filter(|p| &p.scope == scope && p.observed.is_some_and(|seq| seq < before))
			.max_by_key(|p| p.observed)
			.filter(|p| p.claimed.is_none_or(|held| held == turn))
			.and_then(|p| {
				Some(Speech {
					scope: p.scope.clone(),
					text: p.text.clone()?,
					operation: Some(p.operation.clone()),
				})
			});
		(speech, false)
	})
}

pub fn claim(root: &Path, operation: &str, turn: super::ledger::TurnId) -> Result<(), Error> {
	edit(root, |posts| {
		if let Some(post) = posts
			.iter_mut()
			.find(|p| p.operation == operation && p.claimed.is_none())
		{
			post.claimed = Some(turn);
			((), true)
		} else {
			((), false)
		}
	})
}

pub fn forget(root: &Path, conversation: &str) -> Result<(), Error> {
	clear(root, |scope| scope.conversation() == conversation)
}

pub fn reset(root: &Path, held: &Scope) -> Result<(), Error> {
	clear(root, |scope| scope == held)
}

fn clear(root: &Path, remove: impl Fn(&Scope) -> bool) -> Result<(), Error> {
	if !present(root) {
		return Ok(());
	}
	edit(root, |posts| {
		let before = posts.len();
		posts.retain(|p| !remove(&p.scope));
		((), posts.len() != before)
	})
}

pub async fn say(
	turn: &super::act::Turn,
	live: &super::rooms::captp::Live,
	conversation: &str,
	operation: &str,
	text: &str,
) -> Result<rooms_services::session::attached::Sent, rooms_services::session::attached::Error> {
	use rooms_application::content::session::workspace::Conversation;
	if turn.conversation == conversation {
		return live.view.say(operation, conversation, text).await;
	}
	let before = live.view.snapshot().await?;
	let from_room = before.intent.conversations.as_slice().iter().any(
		|row| matches!(row, Conversation::Room(room) if room.id.text().as_str() == Some(turn.conversation.as_str())),
	);
	let scope = Scope::held(&live.grant, conversation, &before)
		.filter(|scope| from_room && scope.kind() == super::rooms::Kind::Direct);
	if let Some(scope) = scope
		&& let Err(error) = reserve(&turn.bot, scope, operation, text)
		&& let Ok(log) = turn.journal()
	{
		log.line(&format!("remembering a private post for its conversation: {error}"));
	}
	live.view.say_from(before, operation, conversation, text).await
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::bot::ledger::TurnId;
	use rooms_testing::scratch::Scratch;

	fn route(grant: &str, conversation: &str, target: &str) -> Scope {
		serde_json::from_value(
			serde_json::json!({"kind":"direct","grant":grant,"conversation":conversation,"target":target}),
		)
		.unwrap()
	}

	#[test]
	fn every_slot_can_confirm_its_widest_escaped_post() {
		use rooms_application::content::session::workspace::MAX_ID_UNITS;
		let dir = Scratch::create("direct-speech-capacity");
		let store = crate::bot::store::Store::open(&dir).unwrap();
		crate::bot::identity::seed(&store).unwrap();
		let key = crate::bot::identity::action_key(store.root()).unwrap();
		let scope = route(&"a".repeat(64), &"\u{1}".repeat(MAX_ID_UNITS), &"b".repeat(64));
		let text = "\u{1}".repeat(context::MAX_TEXT_BYTES + 1);
		let operations: Vec<_> = (0..context::MAX_LINES).map(|_| key.mint().unwrap()).collect();
		for op in &operations {
			reserve(&dir, scope.clone(), op, &text).unwrap();
			confirmed(&dir, &scope, op, &text, Seq(u64::MAX)).unwrap();
			claim(&dir, op, TurnId(u64::MAX)).unwrap();
		}
		let body = std::fs::read(dir.join(DIR).join(FILE)).unwrap();
		assert!(body.len() <= MAX_BYTES);
		let rows: Vec<Post> = serde_json::from_slice(&body).unwrap();
		assert_eq!(rows.len(), context::MAX_LINES);
		assert!(
			rows.iter()
				.all(|p| p.text.as_ref().is_some_and(|t| t.ends_with(" [cut]")))
		);
	}

	#[test]
	fn the_last_confirmed_speech_precedes_the_reply_on_its_exact_original_route() {
		let dir = Scratch::create("direct-speech-order");
		let scope = route("original", "dm", "route");
		let replaced = route("original", "dm", "another");
		let other = route("new grant", "dm", "route");
		reserve(&dir, scope.clone(), "first", "settled second").unwrap();
		reserve(&dir, scope.clone(), "second", "settled first").unwrap();
		reserve(&dir, scope.clone(), "unsent", "private unsent text").unwrap();
		confirmed(&dir, &scope, "second", "settled first", Seq(3)).unwrap();
		confirmed(&dir, &scope, "first", "settled second", Seq(5)).unwrap();
		confirmed(&dir, &other, "unsent", "private unsent text", Seq(6)).unwrap();
		confirmed(&dir, &scope, "unsent", "changed text", Seq(6)).unwrap();
		confirmed(&dir, &scope, "unknown", "a collaborator wrote this", Seq(6)).unwrap();
		assert!(latest(&dir, &scope, Seq(3), TurnId(1)).unwrap().is_none());
		assert_eq!(
			latest(&dir, &scope, Seq(5), TurnId(1)).unwrap().unwrap().text,
			"settled first"
		);
		assert_eq!(
			latest(&dir, &scope, Seq(7), TurnId(1)).unwrap().unwrap().text,
			"settled second"
		);
		assert!(latest(&dir, &replaced, Seq(7), TurnId(1)).unwrap().is_none());
		let rows = std::fs::read_to_string(dir.join(DIR).join(FILE)).unwrap();
		assert!(
			!rows.contains("private unsent text") && !rows.contains("changed text") && !rows.contains("a collaborator")
		);
		claim(&dir, "first", TurnId(1)).unwrap();
		assert!(latest(&dir, &scope, Seq(8), TurnId(2)).unwrap().is_none());
		assert!(latest(&dir, &scope, Seq(8), TurnId(1)).unwrap().is_some());
		reset(&dir, &scope).unwrap();
		assert!(latest(&dir, &scope, Seq(9), TurnId(1)).unwrap().is_none());
	}
}
