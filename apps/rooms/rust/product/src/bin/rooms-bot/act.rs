//! The verbs a harness runs during a turn. Each prints one JSON line and
//! exits. `actions` reads the turn's local record. `say`, `send`, `command`,
//! and `workspace` attach with the bot directory's link under a fresh identity.
//! The verbs take no lease and can run while `serve` holds the directory.
//!
//! A verb takes its bot directory, its conversation, and its ledger id from
//! the turn that runs it, through [`TURN_BOT`], [`TURN_CONVERSATION`], and
//! [`TURN_ID`], which the bot sets for the harness, and never from a flag the
//! agent chooses.
//!
//! `say`, `send`, and a new `command` each take one place in the turn's
//! action budget first, whatever conversation they post to and whether a
//! `--dm` opens one, so one turn acts at most
//! [`MAX_ACTIONS_PER_TURN`](super::actions::MAX_ACTIONS_PER_TURN) times
//! however its agent is prompted.
mod direct;
mod failure;
mod verbs;

use super::{
	actions,
	error::Error,
	fault,
	ledger::{Ledger, TurnId},
	link::Link,
	request::Request,
	rooms::{
		ConversationId,
		captp::{Dial, Live},
	},
	store, words,
};
use serde_json::Value;
use std::{future::Future, path::PathBuf, time::Duration};
use tokio::time::{Instant, timeout_at};

/// One verb a harness runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verb {
	Join,
	Say,
	Send,
	Workspace,
	Command,
	Actions,
}

impl Verb {
	/// The verbs, in the order the prompt shows them. A safe Claude run may
	/// run these and no other glowcap command.
	pub const ALL: [Self; 6] = [
		Self::Say,
		Self::Send,
		Self::Workspace,
		Self::Command,
		Self::Actions,
		Self::Join,
	];

	/// The verb a request names, or none when it names no turn verb.
	pub fn named(name: &str) -> Option<Self> {
		Self::ALL.into_iter().find(|verb| verb.name() == name)
	}

	pub fn name(self) -> &'static str {
		match self {
			Self::Join => "join",
			Self::Say => "say",
			Self::Send => "send",
			Self::Workspace => "workspace",
			Self::Command => "command",
			Self::Actions => "actions",
		}
	}

	/// The flags the verb reads.
	pub fn flags(self) -> &'static [&'static str] {
		match self {
			Self::Join => &["room"],
			Self::Say => verbs::SAY,
			Self::Send => verbs::SEND,
			Self::Workspace | Self::Actions => &[],
			Self::Command => verbs::COMMAND,
		}
	}
}

/// The bot directory of the turn a verb runs in.
pub const TURN_BOT: &str = "GLOWCAP_ROOMS_TURN_BOT";
/// The conversation of the turn a verb runs in.
pub const TURN_CONVERSATION: &str = "GLOWCAP_ROOMS_TURN_CONVERSATION";
/// The ledger id of the turn a verb runs in.
pub const TURN_ID: &str = "GLOWCAP_ROOMS_TURN_ID";
/// When the turn's reply deadline passes, in milliseconds since the Unix
/// epoch. The bot sets it when it starts the agent, and it is the one record
/// of that deadline a verb can read.
pub const TURN_ENDS: &str = "GLOWCAP_ROOMS_TURN_ENDS";
/// How long a verb runs at most, from its own start: connecting, opening a
/// `--dm`, sending, waiting, and keeping all draw from this one budget, and a
/// verb that spends it prints what it knows and exits. It is below
/// [`CLAUDE_BASH_DEFAULT_MS`], so a verb that keeps its budget prints before
/// that harness ends it.
pub const VERB_BUDGET_MS: u64 = 100_000;
/// What a verb leaves of its budget for its last look at the session and its
/// printed answer: every step before the look stops this long before the end.
pub const SETTLE_TAIL_MS: u64 = 10_000;
/// What a verb leaves of the turn after its budget, for the agent to read the
/// answer and finish its reply.
pub const SEND_RESERVE_MS: u64 = 30_000;
/// The default foreground tool timeout the bot sets on every Claude run.
pub const CLAUDE_BASH_DEFAULT_MS: u64 = 120_000;

const _: () = assert!(SETTLE_TAIL_MS < VERB_BUDGET_MS);
const _: () = assert!(VERB_BUDGET_MS < CLAUDE_BASH_DEFAULT_MS);

/// A step of a verb that draws from its [`Budget`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
	/// Dialing the session and attaching.
	Attach,
	/// Reaching the conversation `--dm` names.
	Open,
	/// The call to the session: preparing, sending, waiting, and keeping.
	Call,
	/// The one look at the session that settles an action the call left open.
	Look,
}

impl Step {
	/// Whether a test armed this step's budget as spent.
	fn spent(self) -> bool {
		use fault::Fail;
		fault::fails(match self {
			Self::Attach => Fail::SpentAttach,
			Self::Open => Fail::SpentOpen,
			Self::Call => Fail::SpentCall,
			Self::Look => Fail::SpentLook,
		})
	}
}

/// The one deadline of a verb. Every step but the look stops
/// [`SETTLE_TAIL_MS`] before it, and the look and the close stop at it.
#[derive(Clone, Copy, Debug)]
pub struct Budget {
	/// When the steps before the look stop.
	main_end: Instant,
	/// When the verb is spent.
	end: Instant,
	/// What the budget held at the start, in milliseconds.
	held_ms: u64,
}

impl Budget {
	/// The budget of a verb that starts now in a turn that ends at `ends`:
	/// [`VERB_BUDGET_MS`], and what the turn has left less
	/// [`SEND_RESERVE_MS`] when that is less.
	fn starting(ends: Option<std::time::SystemTime>) -> Self {
		let held_ms = match ends {
			None => VERB_BUDGET_MS,
			Some(ends) => ends
				.duration_since(std::time::SystemTime::now())
				.map_or(0, |left| left.as_millis() as u64)
				.saturating_sub(SEND_RESERVE_MS)
				.min(VERB_BUDGET_MS),
		};
		let end = Instant::now() + Duration::from_millis(held_ms);
		let main_end = end.checked_sub(Duration::from_millis(SETTLE_TAIL_MS)).unwrap_or(end);
		Self { main_end, end, held_ms }
	}

	/// Whether the budget held room for the tail and a step before it.
	pub fn roomy(&self) -> bool {
		self.held_ms > SETTLE_TAIL_MS
	}

	/// What the steps before the look have left, in milliseconds.
	pub fn main_ms(&self) -> u64 {
		self.main_end.saturating_duration_since(Instant::now()).as_millis() as u64
	}

	/// Run `work` as `step`, or none when the budget ends first. A test can arm
	/// a step as spent, and then `work` is never polled.
	pub async fn within<T>(&self, step: Step, work: impl Future<Output = T>) -> Option<T> {
		if step.spent() {
			return None;
		}
		let until = if step == Step::Look { self.end } else { self.main_end };
		timeout_at(until, work).await.ok()
	}

	/// Run `work` until the budget is spent, with no step to arm.
	pub async fn until_spent<T>(&self, work: impl Future<Output = T>) -> Option<T> {
		timeout_at(self.end, work).await.ok()
	}
}

/// The turn a verb runs in.
pub struct Turn {
	pub bot: PathBuf,
	pub conversation: String,
	pub id: TurnId,
	/// What this verb may spend, from its own start.
	pub budget: Budget,
}

impl Turn {
	/// The words every log line about this turn begins with.
	fn said(&self, what: &str) -> String {
		format!("a turn in conversation {} {what}", self.conversation)
	}

	/// The bot's log, which every verb of the turn writes to.
	pub fn journal(&self) -> Result<store::Log, Error> {
		Ok(store::Log::in_directory(&store::directory(&self.bot)?))
	}

	/// Write a line about this turn to the bot's log.
	pub fn log(&self, log: &store::Log, what: &str) {
		log.line(&self.said(what));
	}

	/// Write a line about this turn that must exist, or fail.
	pub fn try_log(&self, log: &store::Log, what: &str) -> std::io::Result<()> {
		log.try_line(&self.said(what))
	}

	/// The turn the bot named in this process's environment. The variables are
	/// trusted: the agent runs with the bot's own rights, so a forged turn id
	/// can only mis-own a claim or note the agent itself writes. An action
	/// takes a place only in the budget its turn opened (`actions::spend`),
	/// and [`Turn::open`] checks the turn against the ledger before an open's
	/// note is written.
	fn current() -> Result<Self, Error> {
		let read = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty());
		let id = read(TURN_ID)
			.and_then(|value| value.into_string().ok())
			.and_then(|value| value.parse().ok());
		match (
			read(TURN_BOT),
			read(TURN_CONVERSATION).map(|value| value.into_string()),
			id,
		) {
			(Some(bot), Some(Ok(conversation)), Some(id)) => Ok(Self {
				bot: bot.into(),
				conversation,
				id: TurnId(id),
				budget: Budget::starting(
					read(TURN_ENDS)
						.and_then(|value| value.into_string().ok())
						.and_then(|value| value.parse::<u64>().ok())
						.map(|millis| std::time::UNIX_EPOCH + Duration::from_millis(millis)),
				),
			}),
			_ => Err(Error::Usage(format!(
				"say, send, join, command, workspace, and actions run only during a bot's turn, which sets {TURN_BOT}, {TURN_CONVERSATION}, and {TURN_ID}"
			))),
		}
	}

	/// Refuse, before a place is taken or anything is sent, a verb that reaches
	/// the session in a turn with no room for its budget's tail.
	fn begin(&self) -> Result<(), Error> {
		if self.budget.roomy() {
			return Ok(());
		}
		Err(Error::Usage(
			"this turn has too little time left to reach the session: nothing was sent and no place was taken. Finish your answer"
				.into(),
		))
	}

	/// Refuse unless this turn is a running turn of its conversation in the
	/// ledger, so a note is only ever written for a turn that exists.
	fn open(&self) -> Result<(), Error> {
		let root = store::directory(&self.bot)?;
		match Ledger::running_turn_in(&root, self.id)? {
			Some(conversation) if conversation.as_str() == self.conversation => Ok(()),
			_ => Err(Error::Usage(format!(
				"turn {} is not a running turn of conversation {}, so it writes no direct-message open",
				self.id.0, self.conversation
			))),
		}
	}

	/// Take one of the turn's action places, before anything reaches the
	/// session.
	fn spend(&self) -> Result<(), Error> {
		let root = store::directory(&self.bot)?;
		actions::spend(&root, &ConversationId::new(self.conversation.as_str()), self.id)
	}
}

pub async fn run(verb: Verb, request: &Request) -> Result<(), Error> {
	let turn = Turn::current()?;
	request.only(verb.flags())?;
	let line = match verb {
		Verb::Join => verbs::join(request, &turn).await?,
		Verb::Say => verbs::say(request, &turn).await?,
		Verb::Send => verbs::send(request, &turn).await?,
		Verb::Command => verbs::command(request, &turn).await?,
		Verb::Workspace => verbs::workspace(&turn).await?,
		Verb::Actions => verbs::actions(&turn)?,
	};
	println!("{line}");
	Ok(())
}

/// Attach for one action. The bot directory's link is the only authority.
async fn attach(turn: &Turn) -> Result<Live, Error> {
	let link = Link::load(&store::directory(&turn.bot)?)?.ok_or_else(|| {
		Error::Config(format!(
			"this bot directory {} Start serve with --link first",
			words::NO_SESSION_LINK
		))
	})?;
	Dial::new(link, None)?
		.attach()
		.await
		.map_err(|cause| failure::attach(&cause))
}

/// Run `action` on a fresh attachment and close it afterwards, all within the
/// verb's budget. A verb whose attach ran out of it sent nothing.
async fn with_view<F, Fut>(turn: &Turn, action: F) -> Result<Value, Error>
where
	F: FnOnce(std::rc::Rc<Live>) -> Fut,
	Fut: std::future::Future<Output = Result<Value, Error>>,
{
	let attached = turn
		.budget
		.within(Step::Attach, attach(turn))
		.await
		.ok_or_else(failure::nothing_sent)??;
	let live = std::rc::Rc::new(attached);
	let result = action(live.clone()).await;
	// best-effort: the verb's own result is the report, and the process
	// exits next, which drops the Host whether or not it closed cleanly or
	// within the budget.
	let _ = turn.budget.until_spent(live.close()).await;
	result
}
