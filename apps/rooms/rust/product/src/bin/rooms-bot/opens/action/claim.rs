//! What a claim says of one action: which verb sent it, to where, and what
//! became of it. The claim is `turn-actions/<operation>.json`, written before
//! the request leaves and kept until its turn stops running, so the turn's
//! next run can be told what the earlier runs did. It holds no text, file
//! name, link, or conversation id the agent never named. A name the agent
//! used is kept whole when it is at most [`MAX_NAME_BYTES`] and not at all
//! beyond that, so nothing is cut.
//!
//! While no outcome is written the claim is held by the verb that sent the
//! action, and the claim names that verb's process. [`Outcome::Cut`] says no
//! verb holds it, and the serving loop settles it from the session's list at
//! once, while the turn runs. A verb writes it only as its last act for an
//! action it ran, once it touches that action's receipt no more. A claim with
//! no outcome whose verb process is gone is read as cut: the harness ended
//! the verb at its own tool timeout, or the verb crashed, and no one else will
//! write its end. Every other outcome is the end of the action's story, and
//! its one wording is [`says`] with its one word, [`word`], which the prompt
//! prints and the `actions` verb lists.
use crate::bot::{group::Verb, ledger::TurnId, rooms::Standing};
use serde::{Deserialize, Serialize};

/// The longest name of a conversation, member, or command a claim keeps.
pub const MAX_NAME_BYTES: usize = 64;

/// A name the agent used, or none when it was longer than [`MAX_NAME_BYTES`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Label(Option<String>);

impl Label {
	pub fn of(name: &str) -> Self {
		Self((name.len() <= MAX_NAME_BYTES).then(|| name.to_owned()))
	}

	/// The name, or `None` when it was too long to keep.
	pub fn name(&self) -> Option<&str> {
		self.0.as_deref()
	}
}

/// Where a post went, as the agent named it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Place {
	/// The turn's own conversation, which the agent did not name.
	Here,
	/// The conversation `--conversation` named.
	Conversation(Label),
	/// The member `--dm` named.
	Dm(Label),
}

/// The verb, and what it was asked, without any content.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum What {
	Say { to: Place },
	Send { to: Place, files: u32 },
	Command { name: Label },
}

/// How an action ended, or that its end is not known yet.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Outcome {
	/// The verb that sent it is gone, and the serving loop is settling it.
	Cut,
	/// It committed, and a post's files stand as said.
	Posted(Standing),
	/// It committed nothing.
	Nothing,
	/// The session cannot say whether it committed.
	Unknown,
}

/// One action: the turn that sent it, what it was, and how it ended.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Action {
	/// The turn that sent it, whose verbs settle it while the turn is open.
	pub turn: TurnId,
	pub what: What,
	/// Absent while the verb that sent it holds it.
	pub outcome: Option<Outcome>,
	/// The verb process that wrote the claim, as it wrote itself in the same
	/// write that made the claim, so the serving loop can tell whether that
	/// process still runs. None where the platform gave the verb no way to
	/// identify itself, and the claim then stays with its verb until its turn
	/// stops running.
	pub verb: Option<Verb>,
}

impl Action {
	/// A claim written by the calling process, which is the verb.
	pub fn new(turn: TurnId, what: What) -> Self {
		Self {
			turn,
			what,
			outcome: None,
			verb: Verb::this_process(),
		}
	}

	/// Whether its request may still hold one of the session's places: no
	/// outcome yet, or one the loop is still settling.
	pub fn held(&self) -> bool {
		matches!(self.outcome, None | Some(Outcome::Cut))
	}

	/// Whether no outcome is written, so the verb that sent it may still settle
	/// it. Whether that verb runs is `keeper`'s answer
	/// (`opens/action.rs`), the one place the claim's verb is judged.
	pub fn unsettled_by_verb(&self) -> bool {
		self.outcome.is_none()
	}
}

/// The one word for how an action stands: `settling` while its end is not
/// known (no outcome, or [`Outcome::Cut`]), then `posted`, `nothing`, or
/// `unknown`. [`says`] tells what each means for the agent.
pub fn word(outcome: Option<&Outcome>) -> &'static str {
	match outcome {
		None | Some(Outcome::Cut) => "settling",
		Some(Outcome::Posted(_)) => "posted",
		Some(Outcome::Nothing) => "nothing",
		Some(Outcome::Unknown) => "unknown",
	}
}

impl Place {
	fn listing(&self) -> serde_json::Value {
		match self {
			Self::Here => serde_json::json!("here"),
			Self::Conversation(label) => serde_json::json!({"conversation": label.name()}),
			Self::Dm(label) => serde_json::json!({"dm": label.name()}),
		}
	}
}

impl Action {
	/// What the `actions` verb lists of this action: the verb, where it went
	/// or what it ran as the agent named it, how it stands, and what that
	/// means. It holds no operation, text, or link.
	pub fn listing(&self) -> serde_json::Value {
		let mut line = match &self.what {
			What::Say { to } => serde_json::json!({"verb": "say", "to": to.listing()}),
			What::Send { to, files } => serde_json::json!({"verb": "send", "to": to.listing(), "files": files}),
			What::Command { name } => serde_json::json!({"verb": "command", "name": name.name()}),
		};
		line["outcome"] = serde_json::json!(word(self.outcome.as_ref()));
		line["says"] = serde_json::json!(says(&self.what, self.outcome.as_ref()));
		line
	}
}

/// What an action's end tells the agent, the one wording for each end. An
/// action with no outcome yet and one the loop is settling read the same.
pub fn says(what: &What, outcome: Option<&Outcome>) -> &'static str {
	use Outcome::{Cut, Nothing, Posted, Unknown};
	match (what, outcome) {
		(_, None | Some(Cut)) => {
			"the bot has not yet learned whether it went through, and records it here once it does. Do not repeat it."
		}
		(What::Say { .. }, Some(Posted(_))) => "the line was posted and stands. Do not say it again.",
		(What::Command { .. }, Some(Posted(_))) => "it ran and committed. Do not run it again.",
		(What::Send { .. }, Some(Posted(Standing::Whole))) => {
			"the line and all its files were posted and stand. Do not send it again."
		}
		(What::Send { .. }, Some(Posted(Standing::Partial))) => {
			"the line was posted but not all its files arrived. Do not send it again."
		}
		(What::Send { .. }, Some(Posted(Standing::Unknown))) => {
			"the line was posted, and some of its files may not have arrived. Do not send it again."
		}
		(What::Say { .. } | What::Send { .. }, Some(Nothing)) => "it did not post. Do it again if it is still needed.",
		(What::Command { .. }, Some(Nothing)) => "it did not run. Run it again if it is still needed.",
		(What::Say { .. } | What::Send { .. }, Some(Unknown)) => {
			"it may or may not have posted, and the bot could not find out. Repeat it only if a duplicate costs less than a missing line."
		}
		(What::Command { .. }, Some(Unknown)) => {
			"it may or may not have run, and the bot could not find out. Repeat it only if running twice costs less than not running."
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_name_is_kept_whole_or_not_at_all() {
		assert_eq!(Label::of("alice").name(), Some("alice"));
		let at_bound = "a".repeat(MAX_NAME_BYTES);
		assert_eq!(Label::of(&at_bound).name(), Some(at_bound.as_str()));
		assert_eq!(Label::of(&"a".repeat(MAX_NAME_BYTES + 1)).name(), None);
	}

	/// Every end of every verb has its words, and a held action and one the
	/// loop is settling read the same.
	#[test]
	fn every_end_of_every_verb_has_words() {
		let here = Place::Here;
		let whats = [
			What::Say { to: here.clone() },
			What::Send { to: here, files: 1 },
			What::Command { name: Label::of("c") },
		];
		let ends = [
			None,
			Some(Outcome::Cut),
			Some(Outcome::Posted(Standing::Whole)),
			Some(Outcome::Posted(Standing::Partial)),
			Some(Outcome::Posted(Standing::Unknown)),
			Some(Outcome::Nothing),
			Some(Outcome::Unknown),
		];
		for what in &whats {
			assert_eq!(says(what, None), says(what, Some(&Outcome::Cut)));
			for end in &ends {
				assert!(!says(what, end.as_ref()).is_empty());
			}
		}
		let send = &whats[1];
		assert_ne!(
			says(send, Some(&Outcome::Posted(Standing::Whole))),
			says(send, Some(&Outcome::Posted(Standing::Partial)))
		);
		assert_ne!(
			says(send, Some(&Outcome::Posted(Standing::Partial))),
			says(send, Some(&Outcome::Posted(Standing::Unknown)))
		);
	}

	/// What each end tells the agent to do, one row per sentence: an action that
	/// may have gone through says not to repeat it, one that did not says to
	/// repeat it if it is still needed, and one the bot could not learn about
	/// leaves the choice with its cost. The first words say what happened.
	#[test]
	fn each_sentence_says_what_happened_and_whether_to_repeat() {
		let here = || Place::Here;
		let say = What::Say { to: here() };
		let send = What::Send { to: here(), files: 2 };
		let command = What::Command { name: Label::of("c") };
		let rows: [(&What, Option<Outcome>, &str, &str); 12] = [
			(&say, None, "the bot has not yet learned", "Do not repeat it"),
			(
				&say,
				Some(Outcome::Cut),
				"the bot has not yet learned",
				"Do not repeat it",
			),
			(
				&say,
				Some(Outcome::Posted(Standing::Whole)),
				"the line was posted and stands",
				"Do not say it again",
			),
			(
				&command,
				Some(Outcome::Posted(Standing::Whole)),
				"it ran and committed",
				"Do not run it again",
			),
			(
				&send,
				Some(Outcome::Posted(Standing::Whole)),
				"the line and all its files were posted",
				"Do not send it again",
			),
			(
				&send,
				Some(Outcome::Posted(Standing::Partial)),
				"the line was posted but not all its files arrived",
				"Do not send it again",
			),
			(
				&send,
				Some(Outcome::Posted(Standing::Unknown)),
				"the line was posted, and some of its files may not",
				"Do not send it again",
			),
			(
				&say,
				Some(Outcome::Nothing),
				"it did not post",
				"Do it again if it is still needed",
			),
			(
				&send,
				Some(Outcome::Nothing),
				"it did not post",
				"Do it again if it is still needed",
			),
			(
				&command,
				Some(Outcome::Nothing),
				"it did not run",
				"Run it again if it is still needed",
			),
			(
				&say,
				Some(Outcome::Unknown),
				"it may or may not have posted",
				"Repeat it only if a duplicate costs less",
			),
			(
				&command,
				Some(Outcome::Unknown),
				"it may or may not have run",
				"Repeat it only if running twice costs less",
			),
		];
		for (what, end, happened, advice) in rows {
			let said = says(what, end.as_ref());
			assert!(said.starts_with(happened) && said.contains(advice), "{said}");
			// The agent is told not to repeat exactly what may have gone through.
			let may_have_gone = !matches!(end, Some(Outcome::Nothing | Outcome::Unknown));
			assert_eq!(said.contains("Do not"), may_have_gone, "{said}");
		}
	}

	#[test]
	fn a_claim_is_held_until_an_outcome_other_than_cut_is_written() {
		let mut action = Action::new(TurnId(1), What::Command { name: Label::of("c") });
		assert!(action.held() && action.unsettled_by_verb());
		action.outcome = Some(Outcome::Cut);
		assert!(action.held() && !action.unsettled_by_verb());
		action.outcome = Some(Outcome::Nothing);
		assert!(!action.held() && !action.unsettled_by_verb());
	}
}
