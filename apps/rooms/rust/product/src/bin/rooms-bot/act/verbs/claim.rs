//! How an action's claim is decided: the call's answer, or one look at the
//! receipt when the call failed, says whether the verb settled the action or
//! leaves it to the serving loop.
use super::super::{Budget, Step, Turn, failure};
use crate::bot::{
	error::Error,
	fault::{self, Kill},
	opens::action::{self, Action, Outcome, What},
	rooms::{Standing, captp::Live},
	store, words,
};
use rooms_services::session::attached::{EffectStatus, Error as ViewError, Files, Recovered, Release, Sent};
use serde_json::{Value, json};
use std::{cell::Cell, future::Future};

/// What a call answered, as the line the verb prints.
pub(super) type Report = fn(Result<Sent, ViewError>, &str) -> Result<Value, Error>;

/// How the action under `operation` settled before the verb exits, by the
/// receipt rule (`engine/deliver/receipt.rs`).
enum Here {
	/// It may still commit, so the serving loop settles it once the turn ends.
	Open,
	/// The call's own answer settled it, and is what the verb prints.
	Answered,
	/// Its outcome is unknown, and its receipt was given back.
	Released,
	/// The call failed, and one look, which sends nothing, found that it
	/// committed. `kept` says what it returned is kept. When it is not, the
	/// receipt was given back (`released`) or the session still holds it.
	/// `standing` is how a post's files stand, and `files` what the look read
	/// of them, none when it read nothing.
	Committed {
		kept: bool,
		released: bool,
		standing: Standing,
		files: Option<Files>,
	},
	/// The call failed, and one look found that it committed nothing.
	Unapplied(EffectStatus),
}

/// Give the receipt of `operation` back, within the look's time.
async fn released(live: &Live, budget: &Budget, operation: &str) -> Here {
	let given = budget.within(Step::Look, live.view.release_effect(operation)).await;
	if matches!(given, Some(Ok(Release::Released | Release::Kept))) {
		Here::Released
	} else {
		Here::Open
	}
}

/// One look at the receipt of `operation`, sending nothing, within the look's
/// time. A look that is spent or fails leaves the action open.
async fn looked(live: &Live, budget: &Budget, operation: &str) -> Here {
	let Some(settled) = budget.within(Step::Look, live.view.settle_effect(operation)).await else {
		return Here::Open;
	};
	match settled {
		Ok(Recovered::Gone) => Here::Answered,
		Ok(Recovered::Committed { files }) => Here::Committed {
			kept: true,
			released: true,
			standing: standing(files.as_ref()),
			files,
		},
		Ok(Recovered::Unapplied(status)) => Here::Unapplied(status),
		Ok(Recovered::Unknown) => released(live, budget, operation).await,
		// The request committed and its result could not be kept: the look
		// found the outcome, and the receipt's fate is the bot's.
		Err(ViewError::Unkept { receipt, files, .. }) => Here::Committed {
			kept: false,
			released: receipt.released(),
			// The look read the post's files before it failed to keep the
			// line, and carries what it read.
			standing: files.as_ref().map_or(Standing::Unknown, |read| standing(Some(read))),
			files,
		},
		Err(ViewError::Unopened { receipt, .. } | ViewError::Forfeited { receipt, .. }) => Here::Committed {
			kept: false,
			released: receipt.released(),
			// A route or a command's result has no files to read.
			standing: Standing::Unknown,
			files: None,
		},
		Ok(Recovered::Pending) | Err(_) => Here::Open,
	}
}

/// How the action under `operation` settled. `result` is what its call
/// answered, or none when the verb's budget ended before the call answered.
/// A committed action had what it returned kept by the view, and one that
/// conflicted, was never sent, or was refused before sending holds no place.
/// A running one may still commit. An unknown one never settles by looking,
/// so its receipt is given back now. Any other failure, and a call with no
/// answer, may or may not have reached the session, so one look tells. A look
/// that finds no receipt the access can settle leaves the call's answer as
/// what the verb prints, and a call with no answer to the bot.
async fn settled_here(live: &Live, budget: &Budget, operation: &str, result: Option<&Result<Sent, ViewError>>) -> Here {
	let answered = |settled: bool| if settled { Here::Answered } else { Here::Open };
	let Some(result) = result else {
		return match looked(live, budget, operation).await {
			Here::Answered => Here::Open,
			here => here,
		};
	};
	match result {
		Ok(Sent {
			status: EffectStatus::Committed | EffectStatus::Conflict | EffectStatus::Unsent,
			..
		})
		| Err(ViewError::Unkeepable { .. } | ViewError::Input(_)) => Here::Answered,
		Ok(Sent {
			status: EffectStatus::Pending,
			..
		}) => Here::Open,
		Ok(Sent {
			status: EffectStatus::Unknown,
			..
		}) => released(live, budget, operation).await,
		Err(
			ViewError::Unkept { receipt, .. }
			| ViewError::Unopened { receipt, .. }
			| ViewError::Forfeited { receipt, .. },
		) => answered(receipt.released()),
		Err(_) => looked(live, budget, operation).await,
	}
}

/// How a post's files stand, from how they ended. Files still filling when
/// the verb exits stop with it.
fn standing(files: Option<&Files>) -> Standing {
	match files {
		None | Some(Files::Complete) => Standing::Whole,
		Some(Files::Incomplete(_) | Files::Unfinished) => Standing::Partial,
	}
}

/// How the action ended when the call's own answer settled it, or none when
/// it committed nothing and leaves nothing to remember. `files` is what the
/// call said of a post's files, and a post that said none leaves them unknown.
fn ended_by(what: &What, result: &Result<Sent, ViewError>, files: Option<&Files>) -> Option<Outcome> {
	// What the call read of a post's files before it failed to keep the line.
	let carried = match result {
		Err(ViewError::Unkept { files, .. }) => files.as_ref(),
		_ => None,
	};
	let files = carried.or(files);
	let posted = || {
		Some(Outcome::Posted(match (what, files) {
			(What::Send { .. }, None) => Standing::Unknown,
			(_, files) => standing(files),
		}))
	};
	match result {
		Ok(Sent {
			status: EffectStatus::Committed,
			..
		})
		| Err(ViewError::Unkept { .. } | ViewError::Forfeited { .. }) => posted(),
		_ => None,
	}
}

/// Add `name` and `value` to a printed line, or to the failure the verb
/// prints in its place.
fn marked(report: Result<Value, Error>, name: &str, value: &str) -> Result<Value, Error> {
	match report {
		Ok(mut line) => {
			if let Some(object) = line.as_object_mut() {
				object.insert(name.into(), json!(value));
			}
			Ok(line)
		}
		Err(error) => Err(failure::marked(error, name, json!(value))),
	}
}

/// Mark the line of an action the serving loop settles once the turn ends,
/// so the agent sends nothing again.
fn settling(report: Result<Value, Error>) -> Result<Value, Error> {
	marked(report, "settling", "bot")
}

/// What a verb prints for a call that ended with no answer, because its
/// budget did: no `status`, because the session said none, what the verb
/// knows, and that it must be listed before it is acted on again. A send's files stop with the verb.
const SPENT: &str = "this command's time ran out before the session reported the action. It may or may not have been done, and the bot settles it. List this turn's actions before acting again";

fn spent_line(what: &What) -> Value {
	let mut line = json!({"ok": true, "reason": SPENT});
	if matches!(what, What::Send { .. }) {
		line["files"] = json!("unfinished");
		line["reason"] = json!(format!("{SPENT}. A send's files stop with this command"));
	}
	line
}

/// What the verb prints for `result`, or for a call with no answer.
fn shown(
	what: &What,
	operation: &str,
	result: Option<Result<Sent, ViewError>>,
	report: Report,
) -> Result<Value, Error> {
	match result {
		Some(result) => report(result, operation),
		None => Ok(spent_line(what)),
	}
}

/// Decide the claim of the action under `operation` by what `result`
/// answered, or by one look when the call has no answer because the verb's
/// budget ended, and report it. A claim the verb settled says how the action
/// ended, or is removed when it committed nothing. One it did not settle is
/// handed to the serving loop, which settles it from the session's list while
/// the turn runs and marks the line. A failed call whose outcome a look found
/// reports what the look found, so the agent is never told a committed action
/// is uncertain.
pub(super) async fn decided(
	turn: &Turn,
	live: &Live,
	operation: &str,
	what: &What,
	files: &Cell<Option<Files>>,
	result: Option<Result<Sent, ViewError>>,
	report: Report,
) -> Result<Value, Error> {
	let root = store::directory(&turn.bot)?;
	let here = settled_here(live, &turn.budget, operation, result.as_ref()).await;
	if matches!(here, Here::Open) {
		hand_over(turn, &root, operation);
		return settling(shown(what, operation, result, report));
	}
	// The claim says how the action ended, or goes when it ended with nothing
	// done. A committed result the session still holds a receipt of is handed
	// over like an open action.
	let said = files.take();
	let ended = match &here {
		Here::Committed { released: false, .. } => None,
		Here::Committed { standing, .. } => Some(Outcome::Posted(*standing)),
		Here::Released => Some(Outcome::Unknown),
		Here::Answered => result.as_ref().and_then(|result| ended_by(what, result, said.as_ref())),
		Here::Unapplied(_) | Here::Open => None,
	};
	files.set(said);
	let held = matches!(here, Here::Committed { released: false, .. });
	let written = match ended {
		Some(outcome) => action::finish(&root, operation, outcome),
		None if held => action::finish(&root, operation, Outcome::Cut),
		None => action::forget(&root, operation),
	};
	if let Err(error) = written {
		unwritten(turn, &root, operation, &error);
	}
	match here {
		// `looked` says the call's own answer failed and a look settled it.
		Here::Committed {
			kept, released, files, ..
		} => {
			let mut line = json!({
				"ok": true, "operation": operation, "status": EffectStatus::Committed.wire(), "looked": true,
			});
			if !kept {
				line["kept"] = json!(false);
				line["receipt"] = json!(if released { "released" } else { "held" });
			}
			// The bot holds the receipt and settles it, as for any action it
			// is left.
			if !released {
				line["settling"] = json!("bot");
			}
			if let Some(Err(ViewError::Uncertain { base, .. })) = &result {
				line["base"] = json!(base);
			}
			// A send says how its files stand, as a send that printed its own
			// answer does, and says so when the look could not read it.
			if matches!(what, What::Send { .. }) {
				line = match files {
					Some(files) => super::with_files(line, Some(files)),
					None => {
						line["files"] = json!("unknown");
						line["reason"] =
							json!("the look found the post committed and could not read how its files stand");
						line
					}
				};
			}
			Ok(line)
		}
		Here::Unapplied(status) => Err(failure::with_operation(failure::unapplied(status.wire()), operation)),
		// An unknown action settles here only by giving its receipt back.
		Here::Released => marked(
			marked(shown(what, operation, result, report), "receipt", "released"),
			"outcome",
			"unknown",
		),
		Here::Answered | Here::Open => shown(what, operation, result, report),
	}
}

/// Leave the action under `operation` to the serving loop, as the last thing
/// this verb does for it. Only a verb writes this for an action it ran, once
/// it will touch that action's receipt no more. A claim with no outcome whose
/// verb process is gone is read as left the same way (`opens/action.rs`), so
/// the loop never settles an action a live verb still works on.
fn hand_over(turn: &Turn, root: &std::path::Path, operation: &str) {
	if let Err(error) = action::finish(root, operation, Outcome::Cut) {
		unwritten(turn, root, operation, &error);
	}
}

fn unwritten(turn: &Turn, root: &std::path::Path, operation: &str, error: &Error) {
	// tolerant: a claim left as it was owns nothing once the turn ends, and
	// the serving loop settles it from the session's list then.
	turn.log(
		&store::Log::in_directory(root),
		&format!("{} could not settle its claim: {error}", words::action(operation)),
	);
}

/// Run one action under `operation`: write its claim, then send it with
/// `call` and decide the claim by the answer. A claim that cannot be written
/// sends nothing. A call the verb's budget ends is never answered, and the
/// action is settled by one look.
pub(super) async fn act(
	turn: &Turn,
	live: &Live,
	operation: &str,
	what: &What,
	files: &Cell<Option<Files>>,
	call: impl Future<Output = Result<Sent, ViewError>>,
	report: Report,
) -> Result<Value, Error> {
	let root = store::directory(&turn.bot)?;
	action::note(&root, operation, &Action::new(turn.id, what.clone()))?;
	fault::hit(Kill::AfterNote);
	fault::held_note(&root).await;
	let answered = turn.budget.within(Step::Call, call).await;
	decided(turn, live, operation, what, files, answered, report).await
}

/// What a look-again verb prints when its budget ended before the look.
pub(super) fn looked_spent(what: &What) -> Value {
	spent_line(what)
}

#[cfg(test)]
mod tests {
	use super::*;

	/// A mark reaches the line a verb prints and the failure it prints in its
	/// place, so an agent reads `receipt` or `settling` either way.
	#[test]
	fn a_mark_reaches_a_printed_line_and_a_printed_failure() {
		let line = marked(Ok(json!({"ok": true})), "receipt", "released").unwrap();
		assert_eq!(line["receipt"], "released");
		let failed = marked(Err(failure::unapplied("conflict")), "receipt", "released").unwrap_err();
		match failed {
			Error::Action { response, .. } => assert_eq!(response["error"]["receipt"], "released"),
			other => panic!("not a printed failure: {other}"),
		}
	}
}
