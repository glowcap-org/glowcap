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
mod harness_sessions;
mod home;
mod identity;
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
mod stamp;
mod status;
mod store;
mod words;

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
		Error::Access { .. } | Error::Asked(_) => "access",
		Error::NotReady(_) => "not-ready",
		Error::Lease(_) => "in-use",
		Error::Storage(_)
		| Error::Unsettled(_)
		| Error::State { .. }
		| Error::Unreadable { .. }
		| Error::TooLarge { .. } => "storage",
		Error::Io { .. } => "io",
		Error::Rooms(_) | Error::Unlisted(_) => "rooms",
		Error::Action { .. } => "action",
		Error::Entropy(_) => "entropy",
	};
	let retry = match error {
		Error::Usage(_) | Error::Config(_) | Error::Access { .. } => Retry::AfterRequestChange,
		_ if error.is_transient() => Retry::Soon,
		_ => Retry::AfterStateChange,
	};
	rooms_services::session::control::Failure::new(class, retry, error).response()
}

/// Run `rooms-bot control <json>`.
pub async fn run(args: Vec<String>) -> Result<(), Error> {
	let body = match args.as_slice() {
		[verb, body] if verb == "control" => body,
		// A process test fills the stand-in's receipt window as another access
		// would, through the window's own reservation.
		#[cfg(feature = "test-support")]
		[verb, directory, count] if verb == "crowd" => {
			let count = count.parse().map_err(|_| Error::Usage("crowd takes a count".into()))?;
			return rooms::files::Files::open(std::path::Path::new(directory))
				.crowd(count)
				.map_err(Error::Rooms);
		}
		_ => return Err(Error::Usage("use glowcap apps rooms bot for Rooms bot commands".into())),
	};
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
