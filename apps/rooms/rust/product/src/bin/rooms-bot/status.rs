//! What `bot status` reports: the facts `serve` last wrote, and whether a
//! `serve` still holds the bot directory.
use super::fault;
use super::{
	config::Config,
	error::Error,
	harness::{FailureKind, Permission},
	home,
	ledger::Unlisted,
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
	/// No longer accepted: revoked, dropped from the session, or out of its
	/// scope. The bot stops serving, because only a new link restores it.
	Revoked,
}

/// What the bot was doing when it last failed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Activity {
	Receiving,
	Sending,
	/// The bot's own failure while running a turn. A turn the agent could not
	/// answer is [`Unanswered`], not this.
	Thinking,
	/// Writing its own state files.
	Saving,
}

/// A failure of `during`, as `last_error` keeps it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Problem {
	pub during: Activity,
	pub message: String,
}

/// The last turn the agent could not answer, and why.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Unanswered {
	/// Why, when the agent said.
	pub kind: Option<FailureKind>,
	pub message: String,
}

/// Everything `bot status` reports of the running bot, as `serve` last wrote it.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Facts {
	pub pid: u32,
	pub harness: String,
	/// The model override, or none when the harness selects its model.
	pub model: Option<String>,
	/// Earlier status files did not record the permission selected at startup.
	pub permission: Option<Permission>,
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
	/// Direct-message opens of the serving access the session has not
	/// settled: those it gave up on or whose note the bot could not read, as
	/// their `.unsettled` notes count them, and those it is giving back, as
	/// their `.giving` notes count them. A `.giving` note drops once the
	/// session takes its receipt. An `.unsettled` one holds a receipt place
	/// until the access is revoked. A revoked access serves nothing, so the
	/// note leaves this count when the bot serves under a new link, which
	/// marks it replaced (`docs/rooms/bot.md`).
	pub unsettled_opens: u64,
	/// The agent's actions the session lists as held by the serving access
	/// that the bot gave up on and the session would not take back. Each holds
	/// one of the session's receipt places until this access is revoked
	/// (`docs/rooms/bot.md`).
	pub unsettled_actions: u64,
	/// Direct-message opens another access than the serving one sent. They
	/// are not counted against the serving access's `--dm` limit, and the
	/// session keeps their receipts under the access that sent them. A start
	/// after the session lets those receipts go drops them (`docs/rooms/bot.md`).
	pub replaced_opens: u64,
	/// The agent's actions the replaced access still held when the bot moved to
	/// the serving one, as the ledger records them. Each can hold one of the
	/// session's receipt places until that access is revoked, and a start drops
	/// each one the session says that access no longer holds.
	pub replaced_actions: u64,
	/// Why the old access of the last replacement could not list the agent's
	/// actions it held, so `replaced_actions` cannot count them. Each can
	/// hold one of the session's places until that access is revoked, which
	/// the bot cannot see. It is recorded when the replacement stores its new
	/// link, and stays until the next replacement stores one.
	pub replaced_unlisted: Option<Unlisted>,
	/// Reply lines the serving access finished by their echo while another
	/// access held their receipts, which the ledger records until the session
	/// says who holds each. They drop as `replaced_opens` do.
	pub replaced_lines: u64,
	/// Reply lines whose receipts the session would not take back while a
	/// look found them committed, still running, or unknown, so each may hold
	/// one of the session's places. The ledger records each once, so a restart
	/// keeps the count, and a record drops once the session no longer lists
	/// its receipt among those this access holds.
	pub unreleased_lines: u64,
	/// The last failure of receiving, sending, saving, or thinking, until that
	/// activity next succeeds.
	pub last_error: Option<Problem>,
	/// The last turn the agent could not answer, until a later turn is
	/// answered. It lives in memory, so a restart clears it.
	pub unanswered: Option<Unanswered>,
}

/// `message` cut to [`MAX_ERROR_BYTES`] at a character boundary.
fn cut(mut message: String) -> String {
	message.truncate(message.floor_char_boundary(MAX_ERROR_BYTES));
	message
}

impl Facts {
	/// Record a failure, cut to [`MAX_ERROR_BYTES`].
	pub fn failed(&mut self, during: Activity, error: impl Display) {
		let message = cut(error.to_string());
		self.last_error = Some(Problem { during, message });
	}

	/// Record a turn the agent could not answer, with its kind when the agent
	/// said why, and what the operator reads, in the fixed words of its
	/// `Cause`, so the status file never holds what the agent printed.
	pub fn gave_up(&mut self, kind: Option<FailureKind>, operator: &str) {
		let message = cut(operator.to_owned());
		self.unanswered = Some(Unanswered { kind, message });
	}

	/// A turn was answered, so the bot no longer has an unanswered turn.
	pub fn answered(&mut self) {
		self.unanswered = None;
		self.recovered(Activity::Thinking);
	}

	/// Clear the last failure when it came from this activity.
	pub fn recovered(&mut self, during: Activity) {
		if self.last_error.as_ref().is_some_and(|problem| problem.during == during) {
			self.last_error = None;
		}
	}

	/// Clear the last failure when it is the one `error` recorded for this
	/// activity, so another source's failure of the same activity stays.
	pub fn cleared(&mut self, during: Activity, error: impl Display) {
		let message = cut(error.to_string());
		if self
			.last_error
			.as_ref()
			.is_some_and(|problem| problem.during == during && problem.message == message)
		{
			self.last_error = None;
		}
	}

	/// Write the facts as a start that holds the lease first does. A start
	/// that cannot replace the previous process's status ends with the error,
	/// because `ready` would read that status under this lease.
	pub fn claim(&self, store: &Store) -> Result<(), Error> {
		store.write(FILE, self)
	}

	/// Write the facts once the start has claimed the file. A status file that
	/// cannot be written then never stops the bot, so the failure goes to the
	/// log.
	pub fn publish(&self, store: &Store) {
		if let Err(error) = self.claim(store) {
			store.log(&format!("writing {FILE}: {error}"));
		}
	}
}

/// The report `bot status` prints for the bot directory `dir`.
pub fn report(dir: &Path) -> Result<Value, Error> {
	let directory = store::directory(dir)?;
	let agent = Config::configured(dir)?.map(|config| {
		json!({
			"harness": config.harness,
			"model": config.model,
			"permission": config.permission,
			"conversation_work_root": store::work_root(&directory),
		})
	});
	// A directory `serve` never reached holds nothing to report, and looking
	// at it must not leave a lease file behind. A first start that has not
	// reached its session may have stored nothing, and the lock file it leaves
	// shows it was served.
	if agent.is_none() && !directory.join(FILE).exists() && !store::was_served(&directory) {
		return Ok(
			json!({"ok": true, "configured": false, "agent": null, "running": false, "status": null, "home": null}),
		);
	}
	// The home is the agent's, so it is counted where it lies, never read
	// from what `serve` last wrote.
	let home = json!({"path": home::path(&directory), "memories": home::count(&directory)});
	// A reader's shared hold proves no `serve` holds the lease and takes
	// nothing a `serve` needs. The facts are read under it.
	let (running, status) = match Store::probe(dir, |root| {
		fault::hold(root).map_err(Error::io("holding a probe"))?;
		store::read_unleased::<Value>(root, FILE)
	})? {
		Some(status) => (false, status),
		None => (true, store::read_unleased::<Value>(&directory, FILE)?),
	};
	Ok(
		json!({"ok": true, "configured": agent.is_some(), "agent": agent, "running": running, "status": status, "home": home}),
	)
}

/// `ready`: succeed only while a `serve` holds the bot directory, has written
/// its status, its access is active, its session answers, and its agent has
/// not been refused its sign-in, so a container health check can tell serving
/// from stopped.
pub fn ready(report: &Value) -> Result<(), Error> {
	let not_ready = |reason: String| Err(Error::NotReady(reason));
	if report["running"] != true {
		return not_ready("no serve holds the bot directory".into());
	}
	let status = &report["status"];
	if status.is_null() {
		return not_ready("serve has not written its status yet".into());
	}
	let facts = match Facts::deserialize(status) {
		Ok(facts) => facts,
		Err(error) => return not_ready(format!("serve's status could not be read: {error}")),
	};
	if facts.access != Access::Active {
		let word = json!(facts.access);
		return not_ready(format!("the session access is {}", word.as_str().unwrap_or("unknown")));
	}
	if facts
		.last_error
		.is_some_and(|problem| problem.during == Activity::Receiving)
	{
		return not_ready("the session is not answering".into());
	}
	if facts
		.unanswered
		.is_some_and(|unanswered| unanswered.kind == Some(FailureKind::SignIn))
	{
		let sign_in = FailureKind::SignIn;
		return not_ready(format!(
			"{}, so no message can be answered until it is signed in again. {}. Then send the bot a message, or restart it, to clear this",
			sign_in.label(),
			sign_in.next_step()
		));
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
	fn a_failure_clears_only_what_its_own_source_recorded() {
		let mut facts = Facts::default();
		facts.failed(Activity::Sending, "the settling loop's failure");
		facts.failed(Activity::Sending, "a delivery's refusal");
		facts.cleared(Activity::Sending, "the settling loop's failure");
		assert!(facts.last_error.is_some(), "another source's failure was cleared");
		facts.cleared(Activity::Saving, "a delivery's refusal");
		assert!(facts.last_error.is_some(), "another activity's clear took it");
		facts.cleared(Activity::Sending, "a delivery's refusal");
		assert!(facts.last_error.is_none());
	}

	fn serving(facts: &Facts) -> Value {
		json!({"running": true, "status": serde_json::to_value(facts).unwrap()})
	}

	fn active() -> Facts {
		Facts {
			access: Access::Active,
			..Facts::default()
		}
	}

	#[test]
	fn ready_means_serving_with_active_access_and_a_session_that_answers() {
		assert!(ready(&serving(&active())).is_ok());
		let mut older = serving(&active());
		let fields = older["status"].as_object_mut().unwrap();
		fields.remove("model");
		fields.remove("permission");
		assert!(ready(&older).is_ok());
		// A failure of another activity is not the session's.
		let mut saving = active();
		saving.failed(Activity::Saving, "x");
		assert!(ready(&serving(&saving)).is_ok());
		let mut limited = active();
		limited.gave_up(Some(FailureKind::UsageLimit), "x");
		assert!(ready(&serving(&limited)).is_ok());

		let mut receiving = active();
		receiving.failed(Activity::Receiving, "x");
		let mut signed_out = active();
		signed_out.gave_up(Some(FailureKind::SignIn), "x");
		let paused = Facts {
			access: Access::Paused,
			..Facts::default()
		};
		let revoked = Facts {
			access: Access::Revoked,
			..Facts::default()
		};
		let refused = [
			json!({"running": false, "status": null}),
			json!({"running": false, "status": serde_json::to_value(active()).unwrap()}),
			json!({"running": true, "status": null}),
			json!({"running": true, "status": {"access": "active"}}),
			serving(&paused),
			serving(&revoked),
			serving(&receiving),
			serving(&signed_out),
		];
		for report in refused {
			assert!(matches!(ready(&report), Err(Error::NotReady(_))), "{report}");
		}
	}

	#[test]
	fn an_unanswered_turn_outlives_other_failures_until_a_turn_is_answered() {
		let mut facts = Facts::default();
		facts.gave_up(
			Some(FailureKind::SignIn),
			"the agent refused its sign-in. Sign the agent in again",
		);
		facts.failed(Activity::Receiving, "lost");
		facts.recovered(Activity::Receiving);
		let mut report = json!({"running": true, "status": serde_json::to_value(&facts).unwrap()});
		report["status"]["access"] = json!("active");
		assert!(matches!(ready(&report), Err(Error::NotReady(_))));
		assert!(facts.unanswered.is_some());

		facts.answered();
		assert!(facts.unanswered.is_none());
	}
}
