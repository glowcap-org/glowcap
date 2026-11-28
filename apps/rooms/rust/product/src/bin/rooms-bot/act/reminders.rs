//! A turn schedules work in its own conversation. An operator can inspect or
//! cancel it with the same live grant and conversation custody keys.
use super::{Budget, Step, Turn, Verb, failure, with_bot_view, with_view};
use crate::bot::{
	config::Config,
	error::Error,
	harness,
	reminders::{self, Kind, Repeat, When},
	request::Request,
	rooms::Scope,
};
use serde_json::{Value, json};
use std::path::Path;

pub(super) async fn run(request: &Request, verb: Verb, turn: &Turn) -> Result<Value, Error> {
	turn.begin()?;
	if verb == Verb::Schedule {
		let config = Config::configured(&turn.bot)?
			.ok_or_else(|| Error::Config("the bot has no stored harness settings".into()))?;
		let adapter = harness::lookup(&config.harness, &config.glowcap).map_err(|e| Error::Config(e.to_string()))?;
		if adapter.scheduled().is_none() {
			return Err(Error::Usage(format!(
				"{} cannot start a tool-free scheduled turn. Use a text reminder here, or configure a harness with tool-free check-ins",
				config.harness
			)));
		}
	}
	with_view(turn, |live| async move {
		let scope = held(&live, &turn.conversation, turn.budget).await?;
		turn.require_running()?;
		match verb {
			Verb::Remind | Verb::Schedule => {
				let (kind, flag) = if verb == Verb::Schedule {
					(Kind::CheckIn, "task")
				} else {
					(Kind::Reminder, "text")
				};
				let order = reminders::Request {
					kind,
					id: required(request, "id")?,
					text: required(request, flag)?,
					when: When::parse(request.single("in")?, request.single("at")?)?,
					repeat: Repeat::parse(request.single("every")?, request.single("count")?)?,
				};
				let reminder = reminders::create(&turn.bot, scope, order, reminders::now(), || turn.spend())?;
				Ok(json!({"ok": true, "reminder": reminder}))
			}
			_ => control(&turn.bot, &scope, verb, request, || turn.spend()),
		}
	})
	.await
}

fn required<'a>(request: &'a Request, flag: &str) -> Result<&'a str, Error> {
	request
		.single(flag)?
		.filter(|v| !v.is_empty())
		.ok_or_else(|| Error::Usage(format!("--{flag} is required")))
}

async fn held(live: &super::Live, conversation: &str, budget: Budget) -> Result<Scope, Error> {
	let snapshot = budget
		.within(Step::Call, live.view.posting_snapshot())
		.await
		.ok_or_else(failure::nothing_sent)?
		.map_err(|cause| failure::call(&cause))?;
	Scope::held(&live.grant, conversation, &snapshot)
		.ok_or_else(|| Error::Usage("this conversation holds no active posting route".into()))
}

fn control(
	root: &Path,
	scope: &Scope,
	verb: Verb,
	request: &Request,
	spend: impl FnOnce() -> Result<(), Error>,
) -> Result<Value, Error> {
	match verb {
		Verb::Reminders => Ok(json!({"ok": true, "reminders": reminders::list(root, scope)?})),
		Verb::CancelReminder => {
			Ok(json!({"ok": true, "reminder": reminders::cancel(root, scope, required(request, "id")?, spend)?}))
		}
		_ => Err(Error::Usage("unknown reminder command".into())),
	}
}

/// Local operators attach through the bot's existing grant. The timer table
/// sees only the scope derived from that live posting route.
pub(super) async fn operator(request: &Request, verb: Verb) -> Result<Value, Error> {
	request.only(if verb == Verb::CancelReminder {
		&["conversation", "id"]
	} else {
		&["conversation"]
	})?;
	let conversation = required(request, "conversation")?;
	if verb == Verb::CancelReminder {
		required(request, "id")?;
	}
	let budget = Budget::starting(None);
	with_bot_view(&request.state, budget, None, |live| async move {
		let scope = held(&live, conversation, budget).await?;
		control(&request.state, &scope, verb, request, || Ok(()))
	})
	.await
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::bot::{
		act::Budget,
		classify::{Seq, Trigger},
		harness::Permission,
		ledger::{Asked, Ledger},
		link::{EXAMPLE, Link},
		rooms::{ConversationId, Cursor, Kind},
		store::Store,
	};
	use rooms_testing::scratch::Scratch;

	#[tokio::test]
	async fn a_configured_codex_turn_refuses_the_task_before_dialing_or_writing_a_schedule() {
		let root = Scratch::create("bot-no-tool-free-codex");
		let store = Store::open(&root).unwrap();
		Link::parse(EXAMPLE).unwrap().save(&store).unwrap();
		Config {
			harness: "codex".into(),
			model: None,
			permission: Permission::Full,
			deadline_secs: 60,
			glowcap: "/bin/true".into(),
			conversation_limit: 5,
			instructions: None,
		}
		.save(&store)
		.unwrap();
		let mut ledger = Ledger::start(&store, Cursor::start()).unwrap();
		let asked = Asked {
			conversation: ConversationId::new("here"),
			kind: Kind::Room,
			triggers: vec![Trigger {
				opening_until: None,
				scope: None,
				seq: Seq(1),
				event: Cursor::new("1").unwrap(),
				line: "one".into(),
				from: Some("someone".into()),
				text: "schedule a task".into(),
				files: vec![],
			}],
		};
		let turn = Turn {
			private_scope: None,
			id: ledger.begin(&store, asked).unwrap(),
			bot: store.root().into(),
			conversation: "here".into(),
			budget: Budget::starting(None),
		};
		let body = json!({"verb":"schedule","state":"","named":{"id":["review"],"in":["1h"],"task":["review"]},"arguments":[]});
		let request = Request::parse(&body.to_string()).unwrap();
		let Err(Error::Usage(reason)) = run(&request, Verb::Schedule, &turn).await else {
			panic!("Codex admitted a scheduled task")
		};
		assert!(reason.contains("codex") && reason.contains("text reminder"), "{reason}");
		assert!(!store.root().join("reminders/schedules.json").exists());
	}
}
