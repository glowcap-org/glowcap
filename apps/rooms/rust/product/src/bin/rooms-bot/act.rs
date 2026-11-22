//! The verbs a harness runs during a turn: `say`, `send`, `command`, and
//! `workspace`. Each is a short-lived process that attaches with the link in
//! the bot directory under a fresh identity, does one thing, prints one JSON
//! line, and exits. It reads the link file and takes no lease, so it works
//! while `serve` runs on the same directory.
//!
//! A verb takes its bot directory and its conversation from the turn that
//! runs it, through [`TURN_BOT`] and [`TURN_CONVERSATION`], which the bot sets
//! for the harness, and never from a flag the agent chooses.
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
	error::Error,
	link::Link,
	request::Request,
	rooms::captp::{Dial, Live},
};
use serde_json::Value;
use std::path::PathBuf;

/// One verb a harness runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verb {
	Say,
	Send,
	Workspace,
	Command,
}

impl Verb {
	/// The verbs, in the order the prompt shows them. A safe Claude run may
	/// run these and no other glowcap command.
	pub const ALL: [Self; 4] = [Self::Say, Self::Send, Self::Workspace, Self::Command];

	/// The verb a request names, or none when it names no turn verb.
	pub fn named(name: &str) -> Option<Self> {
		Self::ALL.into_iter().find(|verb| verb.name() == name)
	}

	pub fn name(self) -> &'static str {
		match self {
			Self::Say => "say",
			Self::Send => "send",
			Self::Workspace => "workspace",
			Self::Command => "command",
		}
	}

	/// The flags the verb reads.
	pub fn flags(self) -> &'static [&'static str] {
		match self {
			Self::Say => verbs::SAY,
			Self::Send => verbs::SEND,
			Self::Workspace => &[],
			Self::Command => verbs::COMMAND,
		}
	}
}

/// The bot directory of the turn a verb runs in.
pub const TURN_BOT: &str = "GLOWCAP_ROOMS_TURN_BOT";
/// The conversation of the turn a verb runs in.
pub const TURN_CONVERSATION: &str = "GLOWCAP_ROOMS_TURN_CONVERSATION";
/// The turn a verb runs in.
pub struct Turn {
	pub bot: PathBuf,
	pub conversation: String,
}

impl Turn {
	/// The turn the bot named in this process's environment.
	fn current() -> Result<Self, Error> {
		let read = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty());
		match (read(TURN_BOT), read(TURN_CONVERSATION).map(|value| value.into_string())) {
			(Some(bot), Some(Ok(conversation))) => Ok(Self {
				bot: bot.into(),
				conversation,
			}),
			_ => Err(Error::Usage(format!(
				"say, send, command, and workspace run only during a bot's turn, which sets {TURN_BOT} and {TURN_CONVERSATION}"
			))),
		}
	}

	/// Take one of the turn's action places, before anything reaches the
	/// session.
	fn spend(&self) -> Result<(), Error> {
		let root = super::store::directory(&self.bot)?;
		super::actions::spend(&root, &super::rooms::ConversationId::new(self.conversation.as_str()))
	}
}

pub async fn run(verb: Verb, request: &Request) -> Result<(), Error> {
	let turn = Turn::current()?;
	request.only(verb.flags())?;
	let line = match verb {
		Verb::Say => verbs::say(request, &turn).await?,
		Verb::Send => verbs::send(request, &turn).await?,
		Verb::Command => verbs::command(request, &turn).await?,
		Verb::Workspace => verbs::workspace(&turn).await?,
	};
	println!("{line}");
	Ok(())
}

/// Attach for one action. The bot directory's link is the only authority.
async fn attach(turn: &Turn) -> Result<Live, Error> {
	let link = Link::load(&super::store::directory(&turn.bot)?)?.ok_or_else(|| {
		Error::Config("this bot directory has no session link yet. Start serve with --link first".into())
	})?;
	Dial::new(link, None)?
		.attach()
		.await
		.map_err(|cause| failure::attach(&cause))
}

/// Run `action` on a fresh attachment and close it afterwards.
async fn with_view<F, Fut>(turn: &Turn, action: F) -> Result<Value, Error>
where
	F: FnOnce(std::rc::Rc<Live>) -> Fut,
	Fut: std::future::Future<Output = Result<Value, Error>>,
{
	let live = std::rc::Rc::new(attach(turn).await?);
	let result = action(live.clone()).await;
	// best-effort: the verb's own result is the report, and the process
	// exits next, which drops the Host whether or not it closed cleanly.
	let _ = live.close().await;
	result
}
