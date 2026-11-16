//! A callback refusal reaches its caller as a bare status, because these
//! callbacks have no call handle to carry a reason. This owner lets the session
//! tell its failure reporter each distinct reason once, in bounded memory.
use glowcap::loam;
use std::{
	cell::RefCell,
	fmt::{self, Write},
	hash::{DefaultHasher, Hasher},
};

/// The session verbs sent by the page steps that read or acquire a committed
/// result, the steps `AcquisitionStage` names in
/// `web/ui/session/managed/operation.ts`:
/// - `effect-status`, `effect-result`, `effect-adopted` and `resume-effect`
///   (`workspace/observer.rs`, `workspace/recovery.rs`).
/// - `addressed-snapshot`, the page's workspace read (`workspace.rs`).
/// - `acquire-result-workspace` and `acquire-created-room`, which end the
///   acquisition (`workspace/results.rs`). When the result maps a manager
///   link, the step can first send `room-identity-reader`
///   (`workspace/authority.rs`).
///
/// After a commit the page also sends `effect-intent`, `effect-inventory`,
/// `release-effect` and `effect-reader` from steps with no stage, so they are
/// outside the set. So are `roomIdentity` and `managedRoomIdentity`, which a
/// step sends to the room's reader.
const REPORTED_VERBS: [&str; 8] = [
	"effect-status",
	"effect-result",
	"effect-adopted",
	"resume-effect",
	"addressed-snapshot",
	"acquire-result-workspace",
	"acquire-created-room",
	"room-identity-reader",
];

/// One session reports at most this many distinct refusals, then one final line.
const REPORT_CAP: usize = 32;

struct Digest(DefaultHasher);
impl Write for Digest {
	fn write_str(&mut self, text: &str) -> fmt::Result {
		self.0.write(text.as_bytes());
		Ok(())
	}
}

#[derive(Default)]
struct Seen {
	/// The verb's index in `REPORTED_VERBS` and a digest of the cause text. The
	/// digest keeps each entry the same size however long a cause is, and the
	/// list never grows past `REPORT_CAP`. A collision only hides a second
	/// cause for the same verb.
	entries: Vec<(usize, u64)>,
	/// The final line has been reported, so every later refusal is silent.
	closed: bool,
}

#[derive(Default)]
pub(super) struct Refusals(RefCell<Seen>);

impl Refusals {
	/// Report one refused callback of `verb` through `sink`, as `refused <verb>`
	/// with the refusal as the session holds it. Each distinct verb and cause
	/// reports once. The first distinct refusal past the cap reports one final
	/// line, and later ones report nothing. Nothing is recorded when nothing is
	/// `reporting`, and a verb outside `REPORTED_VERBS` is never reported.
	pub(super) fn report(
		&self,
		verb: &str,
		error: &glowcap::Error,
		reporting: bool,
		sink: &dyn Fn(&str, &glowcap::Error),
	) {
		if !reporting {
			return;
		}
		let Some(index) = REPORTED_VERBS.iter().position(|known| *known == verb) else {
			return;
		};
		let mut seen = self.0.borrow_mut();
		if seen.closed {
			return;
		}
		let mut digest = Digest(DefaultHasher::new());
		// best-effort: a cause whose Display fails hashes only what it wrote, which at worst merges two causes
		let _ = write!(digest, "{error}");
		let entry = (index, digest.0.finish());
		if seen.entries.contains(&entry) {
			return;
		}
		if seen.entries.len() == REPORT_CAP {
			seen.closed = true;
			drop(seen);
			sink(
				"refused callbacks",
				&loam::refusal("further refused callbacks are not reported"),
			);
			return;
		}
		seen.entries.push(entry);
		drop(seen);
		sink(&format!("refused {verb}"), error);
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn lines(run: impl FnOnce(&Refusals, &dyn Fn(&str, &glowcap::Error))) -> Vec<(String, String)> {
		let lines = RefCell::new(Vec::new());
		let sink = |scope: &str, error: &glowcap::Error| lines.borrow_mut().push((scope.to_owned(), error.to_string()));
		run(&Refusals::default(), &sink);
		lines.into_inner()
	}

	#[test]
	fn each_distinct_pair_reports_once_then_one_final_line_then_silence() {
		let lines = lines(|refusals, sink| {
			let unknown = loam::refusal("unknown effect");
			refusals.report("effect-result", &unknown, true, sink);
			refusals.report("effect-result", &unknown, true, sink);
			refusals.report("effect-status", &unknown, true, sink);
			refusals.report("snapshot", &unknown, true, sink);
			for number in 0..REPORT_CAP - 2 {
				refusals.report("effect-result", &loam::refusal(format!("cause {number}")), true, sink);
			}
			for number in 0..10 {
				refusals.report("effect-result", &loam::refusal(format!("later {number}")), true, sink);
			}
			refusals.report("effect-result", &unknown, true, sink);
		});
		assert_eq!(lines.len(), REPORT_CAP + 1, "the cap plus one final line");
		assert_eq!(lines[0].0, "refused effect-result");
		assert!(lines[0].1.contains("unknown effect"));
		assert_eq!(lines[1].0, "refused effect-status");
		assert_eq!(lines[REPORT_CAP].0, "refused callbacks");
		assert!(
			lines[REPORT_CAP]
				.1
				.contains("further refused callbacks are not reported")
		);
	}

	#[test]
	fn nothing_is_recorded_without_a_reporter_or_for_a_verb_outside_the_set() {
		let lines = lines(|refusals, sink| {
			for number in 0..REPORT_CAP * 2 {
				refusals.report("effect-result", &loam::refusal(format!("cause {number}")), false, sink);
				refusals.report("effect-reader", &loam::refusal(format!("cause {number}")), true, sink);
			}
			refusals.report("effect-result", &loam::refusal("first"), true, sink);
		});
		assert_eq!(lines.len(), 1, "unreported refusals did not consume the cap");
		assert!(lines[0].1.contains("first"));
	}
}
