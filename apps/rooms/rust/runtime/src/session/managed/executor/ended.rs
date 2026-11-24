//! A paused job with nothing left to observe is retired by the next
//! admission, which frees its seat: one whose receipt the committed record
//! already settled, and one whose commit is confirmed absent.
use super::super::State;
use rooms_application::content::session::custody::{EffectReceipt, Outcome, References};
use rooms_glowcap::client::{Deadline, Tasks};

/// Retire every paused job whose receipt in `effects` is settled, and every
/// paused job still confirming whose commit is confirmed absent. `effects`
/// is the committed record the admitting verb read, so this decides from
/// state that stands whether or not that verb commits. A job pauses in its
/// settling phase when the settlement's answer misses its deadline, and the
/// settlement can still commit after that. Its receipt is then settled while
/// the job waits for a resume that cannot change the outcome, and without
/// this the job would hold its seat, and pin its receipt in the window, until
/// its source gave the receipt back or the session restarted.
///
/// A job that paused while confirming holds no receipt when its commit was
/// abandoned (Loam can take a submitted commit through recovery to aborted
/// after the observation deadline), so nothing in `effects` ends it. It is
/// retired on its own handle (`Job::confirms_absent`), never on the receipt's
/// absence from `effects`, because that also reads a commit still pending,
/// which may yet install and resume. Absence is final, and the job retires
/// unsettled, so a membership it admitted learns absent as the worker reports.
///
/// A job whose receipt is still unresolved stays, because a refused or
/// unanswered settlement is resumed and settled again by its source. A job
/// whose receipt left the window stays too, since nothing here says how it
/// ended. A running job is never retired (`retire`).
///
/// Retiring a settled job loses nothing the session still owes:
/// - The line activity a committed post captured is published here, as the
///   worker publishes it once its settlement answers, so a viewer sees the
///   line as if the answer had come in time. A settlement that committed no
///   line publishes nothing.
/// - A membership the job admitted reported its endpoint before the job
///   reached its settling phase, so that report stays, and the membership
///   worker's own cleanup (`supervision/observation.rs`) sends the `leave`
///   when the membership closes, as it does for every membership.
pub(in crate::session::managed) fn retire_ended<P: Tasks + Deadline + Clone + 'static, R: References>(
	owner: &State<P>,
	effects: &[EffectReceipt<R>],
) {
	let hold_settled = crate::session::fault::holds_settled_retirement();
	let settled: Vec<(String, bool)> = owner
		.jobs
		.borrow()
		.iter()
		.filter(|(_, job)| job.is_paused())
		.filter_map(|(id, job)| {
			if job.confirms_absent() {
				return Some((id.clone(), false));
			}
			if hold_settled {
				return None;
			}
			let receipt = effects
				.iter()
				.find(|receipt| receipt.operation.text().as_str() == Some(id.as_str()))?;
			match receipt.outcome {
				Outcome::Unresolved => None,
				Outcome::Committed { .. } => Some((id.clone(), true)),
				Outcome::Unknown { .. } | Outcome::KnownAbsent | Outcome::Refused { .. } => Some((id.clone(), false)),
			}
		})
		.collect();
	for (id, committed) in settled {
		super::retire(owner, &id, committed);
	}
}
