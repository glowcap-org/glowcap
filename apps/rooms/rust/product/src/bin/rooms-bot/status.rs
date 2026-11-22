//! What `bot status` reports: the facts `serve` last wrote, and whether a
//! `serve` still holds the bot directory.
use super::{
	config::Config,
	error::Error,
	home,
	rooms::Cursor,
	store::{self, Store},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{fmt::Display, path::Path};

const FILE: &str = "status.json";
/// The longest error message status keeps.
pub const MAX_ERROR_BYTES: usize = 512;

/// What the session's access grant allows the bot right now.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Access {
	/// No call has reached the session yet in this `serve`.
	#[default]
	Unknown,
	/// The session serves the grant.
	Active,
	/// Paused by its grantor. The bot polls slowly until it resumes.
	Paused,
	/// Revoked. The bot polls slowly in case a new grant reaches it.
	Revoked,
	/// The session refuses to serve this grant.
	Refused,
}

/// What the bot was doing when it last failed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Activity {
	Receiving,
	Sending,
	/// Running the harness for a turn.
	Thinking,
	/// Writing its own state files.
	Saving,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Problem {
	pub during: Activity,
	pub message: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Facts {
	pub pid: u32,
	pub harness: String,
	pub cursor: Cursor,
	pub access: Access,
	/// Triggers waiting for a turn.
	pub queued: usize,
	pub open_turns: usize,
	/// Open turns whose reply is written and waiting for the session to take it.
	pub sending: usize,
	/// Turns finished since the bot directory was first served, from the
	/// ledger, so a restart does not reset it.
	pub turns_finished: u64,
	/// How many times the session reported missed events.
	pub gaps: u64,
	/// How many times the session reported events it could not present.
	pub unavailable: u64,
	/// Events skipped since this serve started because their rows could not
	/// be read.
	pub unreadable: u64,
	/// Lines given up on since this serve started, neither confirmed nor sent
	/// again, because the session could no longer say whether they posted.
	pub unconfirmed: u64,
	/// Direct-message opens the bot gave up on, or whose note it could not
	/// read, neither kept nor given back, as their notes set aside in the bot
	/// directory count them. The session keeps their receipts until the
	/// access that sent them is revoked.
	pub unsettled_opens: u64,
	/// The last failure, until the same activity next succeeds.
	pub last_error: Option<Problem>,
}

impl Facts {
	/// Record a failure, cut to [`MAX_ERROR_BYTES`].
	pub fn failed(&mut self, during: Activity, error: impl Display) {
		let mut message = error.to_string();
		message.truncate(message.floor_char_boundary(MAX_ERROR_BYTES));
		self.last_error = Some(Problem { during, message });
	}

	/// Clear the last failure when it came from this activity.
	pub fn recovered(&mut self, during: Activity) {
		if self.last_error.as_ref().is_some_and(|problem| problem.during == during) {
			self.last_error = None;
		}
	}

	/// Write the facts. A status file that cannot be written never stops the
	/// bot, so the failure goes to the log.
	pub fn publish(&self, store: &Store) {
		if let Err(error) = store.write(FILE, self) {
			store.log(&format!("writing {FILE}: {error}"));
		}
	}
}

pub fn report(dir: &Path) -> Result<Value, Error> {
	let directory = store::directory(dir)?;
	let configured = Config::configured(dir)?.is_some();
	// A directory `serve` never reached holds nothing to report, and looking
	// at it must not leave a lease file behind.
	if !configured && !directory.join(FILE).exists() {
		return Ok(json!({"ok": true, "configured": false, "running": false, "status": null, "home": null}));
	}
	// The home is the agent's, so it is counted where it lies, never read
	// from what `serve` last wrote.
	let home = json!({"path": home::path(&directory), "memories": home::count(&directory)});
	// Holding the lease proves no `serve` does, and keeps one from starting
	// while the facts are read.
	let (running, status) = match Store::open(dir) {
		Ok(held) => (false, held.read::<Value>(FILE)?),
		Err(Error::Lease(_)) => (true, store::read_unleased::<Value>(&directory, FILE)?),
		Err(error) => return Err(error),
	};
	Ok(json!({"ok": true, "configured": configured, "running": running, "status": status, "home": home}))
}

/// `ready`: succeed only while a `serve` holds the bot directory and its
/// session answers, so a container health check can tell serving from stopped.
pub fn ready(report: &Value) -> Result<(), Error> {
	let not_ready = |reason: &str| Err(Error::NotReady(reason.to_owned()));
	if report["running"] != true {
		return not_ready("no serve holds the bot directory");
	}
	let status = &report["status"];
	if status.is_null() {
		return not_ready("serve has not written its status yet");
	}
	if status["access"] != "active" {
		return not_ready(&format!(
			"the session access is {}",
			status["access"].as_str().unwrap_or("unknown")
		));
	}
	if status["last_error"]["during"] == "receiving" {
		return not_ready("the session is not answering");
	}
	Ok(())
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn the_last_error_is_bounded_and_cleared_by_its_own_activity() {
		let mut facts = Facts::default();
		facts.failed(Activity::Sending, "é".repeat(MAX_ERROR_BYTES));
		let kept = facts.last_error.as_ref().map(|problem| problem.message.len());
		assert!(kept.is_some_and(|len| len <= MAX_ERROR_BYTES));
		facts.recovered(Activity::Receiving);
		assert!(facts.last_error.is_some(), "another activity cleared the error");
		facts.recovered(Activity::Sending);
		assert!(facts.last_error.is_none());
	}

	#[test]
	fn ready_means_serving_with_active_access_and_a_session_that_answers() {
		let serving = |status: Value| json!({"running": true, "status": status});
		assert!(ready(&serving(json!({"access": "active", "last_error": null}))).is_ok());
		// A failure of another activity is not the session's.
		assert!(
			ready(&serving(
				json!({"access": "active", "last_error": {"during": "thinking", "message": "x"}})
			))
			.is_ok()
		);
		let refused = [
			json!({"running": false, "status": null}),
			json!({"running": false, "status": {"access": "active"}}),
			serving(Value::Null),
			serving(json!({"access": "paused"})),
			serving(json!({"access": "revoked"})),
			serving(json!({"access": "active", "last_error": {"during": "receiving", "message": "x"}})),
		];
		for report in refused {
			assert!(matches!(ready(&report), Err(Error::NotReady(_))), "{report}");
		}
	}
}
