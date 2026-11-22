//! The Rooms bot: a long-running process between a Rooms session and a coding
//! harness. It reads the session's events, runs the harness for each message
//! that addresses the bot, and posts the harness's final message as the reply.
//! Zig owns argv and help. This private binary receives the parsed request.
mod act;
mod actions;
mod classify;
mod config;
mod context;
mod conversations;
mod engine;
mod error;
mod fault;
mod gate;
mod group;
mod harness;
mod home;
mod inbox;
mod ledger;
mod link;
mod opens;
mod prompt;
mod reply;
mod request;
mod rooms;
mod runner;
mod serve;
mod sessions;
mod stamp;
mod status;
mod store;

pub use error::Error;
use request::Request;
use rooms_application::failure::Retry;
use serde_json::Value;

/// The machine-readable line a failed command prints on stdout, in the
/// `{"ok":false,"error":{class,retry,message}}` shape `session access`
/// prints, with the same class names for the same causes.
pub fn failure_line(error: &Error) -> Value {
	if let Error::Action { response, .. } = error {
		return response.clone();
	}
	let class = match error {
		Error::Usage(_) => "invalid",
		Error::Config(_) => "config",
		Error::NotReady(_) => "not-ready",
		Error::Lease(_) => "in-use",
		Error::Storage(_)
		| Error::Unsettled(_)
		| Error::State { .. }
		| Error::Unreadable { .. }
		| Error::TooLarge { .. } => "storage",
		Error::Io { .. } => "io",
		Error::Rooms(_) => "rooms",
		Error::Action { .. } => "action",
		Error::Entropy(_) => "entropy",
	};
	let retry = match error {
		Error::Usage(_) | Error::Config(_) => Retry::AfterRequestChange,
		_ if error.is_transient() => Retry::Soon,
		_ => Retry::AfterStateChange,
	};
	rooms_services::session::control::Failure::new(class, retry, error).response()
}

/// Run `rooms-bot control <json>`.
pub async fn run(args: Vec<String>) -> Result<(), Error> {
	let [verb, body] = args.as_slice() else {
		return Err(Error::Usage("use glowcap apps rooms bot for Rooms bot commands".into()));
	};
	if verb != "control" {
		return Err(Error::Usage("use glowcap apps rooms bot for Rooms bot commands".into()));
	}
	let request = Request::parse(body)?;
	match request.verb.as_str() {
		"serve" => serve::run(&request).await,
		"status" => {
			request.only(&[])?;
			println!("{}", status::report(&request.state)?);
			Ok(())
		}
		"ready" => {
			request.only(&[])?;
			status::ready(&status::report(&request.state)?)
		}
		other => match act::Verb::named(other) {
			Some(verb) => act::run(verb, &request).await,
			None => Err(Error::Usage(format!("unknown bot command {other:?}"))),
		},
	}
}
