//! The answer to a release of an operation whose receipt the committed record
//! does not hold.
use super::{Job, retire};
use crate::session::managed::State;
use glowcap::Ref;
use rooms_application::content::session::effects::Release;
use rooms_glowcap::client::{Deadline, Tasks};

/// How a job's installed commit stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Commit {
	/// No observer waits on a commit, so nothing can install a receipt later.
	Settled,
	/// The commit has not settled, so the job may yet install a receipt.
	Pending,
	/// The commit is confirmed absent, which is final.
	Absent,
}
/// What a release of an unrecorded operation does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Answer {
	/// Nothing is held and nothing can install.
	Released,
	/// A receipt may still install, so nothing changes.
	Running,
	/// The commit never landed, so the job's seat is freed first.
	Retire,
}
/// The answer for `asker` given the job under the operation: its source and
/// the commit it waits on. Only the source that sent the request learns of its
/// job, and any other answers as if there were none.
///
/// A commit read as absent is final because Loam's rule is that a release
/// callback's snapshot is never older than a landing the worker has observed,
/// so a landing that has not shown cannot install under a released operation.
/// That rule is Loam's, and nothing here proves it.
fn answer<S: PartialEq>(job: Option<(Option<&S>, Commit)>, asker: &S) -> Answer {
	match job {
		Some((Some(owner), commit)) if owner == asker => match commit {
			Commit::Settled => Answer::Released,
			Commit::Pending => Answer::Running,
			Commit::Absent => Answer::Retire,
		},
		_ => Answer::Released,
	}
}
impl<P: Tasks> Job<P> {
	fn commit(&self) -> Commit {
		if self.confirming.strong_count() == 0 {
			Commit::Settled
		} else if self.confirms_absent() {
			Commit::Absent
		} else {
			Commit::Pending
		}
	}
}
/// The answer to a release of `id` by `source` when the committed record holds
/// no receipt for it. Nothing is held, so the answer is released, with one
/// exception: a job of `source` whose installed commit has not settled,
/// whether its worker runs or is paused. If the commit is confirmed absent
/// the release retires a paused job, as an admission would (`retire_ended`),
/// and answers released. If the commit is pending the job may yet install a
/// receipt and dispatch, so the answer is running and nothing changes, and the
/// release asked again settles it either way. The job's source is its own
/// field, so no work lock is consulted.
pub(in crate::session::managed) fn release_unrecorded<P: Tasks + Deadline + Clone + 'static>(
	owner: &State<P>,
	id: &str,
	source: &Ref,
) -> Release {
	let answered = {
		let jobs = owner.jobs.borrow();
		answer(jobs.get(id).map(|job| (job.source.as_ref(), job.commit())), source)
	};
	match answered {
		Answer::Released => Release::Released,
		Answer::Running => Release::Running,
		Answer::Retire => {
			retire(owner, id, false);
			Release::Released
		}
	}
}

#[cfg(test)]
mod tests {
	use super::{Answer, Commit, answer};

	#[test]
	fn only_the_jobs_own_source_learns_of_it_and_only_a_pending_commit_answers_running() {
		let job = |source: &'static i32, commit| Some((Some(source), commit));
		assert_eq!(answer(job(&1, Commit::Pending), &1), Answer::Running);
		assert_eq!(answer(job(&1, Commit::Absent), &1), Answer::Retire);
		assert_eq!(answer(job(&1, Commit::Settled), &1), Answer::Released);
		for commit in [Commit::Pending, Commit::Absent, Commit::Settled] {
			assert_eq!(answer(job(&1, commit), &2), Answer::Released, "{commit:?}");
		}
		assert_eq!(answer(Some((None, Commit::Pending)), &1), Answer::Released);
		assert_eq!(answer::<i32>(None, &1), Answer::Released);
	}
}
