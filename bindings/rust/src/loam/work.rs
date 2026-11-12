//! Storage jobs borrow storage work until the blocking worker retires.
use super::{AttachmentInner, Executor, check};
use crate::Result;
use crate::sys::loam as ffi;
use std::rc::Rc;
use std::sync::{Arc, Condvar, Mutex};

#[derive(Default)]
struct Completion {
	retired: Mutex<Option<WorkerOutcome>>,
	changed: Condvar,
}
#[derive(Clone, Copy)]
enum WorkerOutcome {
	Unstarted,
	Finished(i32),
}
struct WorkerDone {
	completion: Arc<Completion>,
	outcome: WorkerOutcome,
}
impl WorkerDone {
	fn finish(&mut self, code: i32) {
		self.outcome = WorkerOutcome::Finished(code);
	}
}
impl Drop for WorkerDone {
	fn drop(&mut self) {
		*self
			.completion
			.retired
			.lock()
			.unwrap_or_else(|error| error.into_inner()) = Some(self.outcome);
		self.completion.changed.notify_all();
	}
}
/// One storage effect run on the blocking worker through the store's executor.
struct StorageJob {
	executor: Arc<dyn Executor>,
	work: *mut ffi::GlowcapLoamWork,
	done: WorkerDone,
}
// SAFETY: the raw `work` pointer is the only non-`Send` field. The job holds the exclusive work handle, and the
// off-thread rationale for the executor lives on `Executor`. Only the result is written; Host installation stays local.
unsafe impl Send for StorageJob {}
impl StorageJob {
	fn run(mut self) -> Result<()> {
		let code = self.executor.work_run(self.work);
		self.done.finish(code);
		self.executor.check(code)
	}
}
struct Retirement {
	owner: Rc<AttachmentInner>,
	raw: *mut ffi::GlowcapLoamWork,
	completion: Arc<Completion>,
	completed: bool,
	reported: bool,
}
impl Retirement {
	fn join(&self) -> WorkerOutcome {
		let mut retired = self
			.completion
			.retired
			.lock()
			.unwrap_or_else(|error| error.into_inner());
		while retired.is_none() {
			retired = self
				.completion
				.changed
				.wait(retired)
				.unwrap_or_else(|error| error.into_inner());
		}
		retired.expect("worker retirement was observed")
	}
	fn complete(&mut self) -> i32 {
		let outcome = self.join();
		if !self.reported {
			// The companion refuses before doing I/O; executed storage failures
			// are delivered as work results with an OK run status.
			if matches!(outcome, WorkerOutcome::Unstarted)
				|| matches!(outcome, WorkerOutcome::Finished(code) if code != crate::sys::OK)
			{
				// SAFETY: `self.raw` is this `Retirement`'s work handle from `glowcap_loam_next_work`, not yet
				// completed or released, and `join` above has observed the worker's retirement, so no storage access to
				// it remains.
				let code = unsafe { ffi::glowcap_loam_work_report_unstarted(self.raw) };
				if code != crate::sys::OK {
					return code;
				}
			}
			self.reported = true;
		}
		let mut completed = 0;
		// SAFETY: `self.raw` is this `Retirement`'s work handle from `glowcap_loam_next_work`, not yet released, and
		// `join` above has observed the worker's retirement; `completed` is a local out-parameter the callee writes.
		let code = unsafe { ffi::glowcap_loam_work_complete(self.raw, &mut completed) };
		self.completed = completed != 0;
		code
	}
}
impl Drop for Retirement {
	fn drop(&mut self) {
		// Dropping a work task cannot free an active LMDB worker's buffers.
		// A task dropped with its LocalSet joins before installation and
		// release.
		if !self.completed {
			let rc = self.complete();
			if self.completed
				&& rc != ffi::GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED
				&& let Err(error) = check(rc)
			{
				self.owner.host.record_background_failure(error);
			}
		}
		if !self.completed {
			crate::finalizer::park_loam_work(Rc::clone(&self.owner), self.raw);
			self.owner.host.schedule_kick_or_record();
		// SAFETY: `self.raw` is this `Retirement`'s work handle from `glowcap_loam_next_work`; the branch is reached
		// only when `completed` is set, after the worker retired and the core took the result, and a refusal parks the
		// handle rather than reusing it.
		} else if let Err(error) = check(unsafe { ffi::glowcap_loam_work_release(self.raw) }) {
			self.owner.host.record_background_failure(error);
			crate::finalizer::park_loam_work(Rc::clone(&self.owner), self.raw);
		}
	}
}
/// One running storage job in the attachment's count, which close joins and
/// a full worker waits on. It leaves the count after physical retirement.
struct Counted(Rc<AttachmentInner>);
impl Drop for Counted {
	fn drop(&mut self) {
		self.0.work_retired();
	}
}
/// Built before the task is admitted, so a task that never runs still
/// retires its work as unstarted. Fields drop in order: the queued job first,
/// so `retirement` can join it, and the count last.
struct Custody {
	job: Option<StorageJob>,
	retirement: Retirement,
	_counted: Counted,
}

/// Start one storage effect on the blocking executor as a Host-owned task.
/// The task kicks the drain once the work retires.
pub(super) fn start(owner: Rc<AttachmentInner>, raw: *mut ffi::GlowcapLoamWork) -> Result<()> {
	owner.work_started();
	let completion = Arc::new(Completion::default());
	let custody = Custody {
		job: Some(StorageJob {
			executor: Arc::clone(&owner.store.executor),
			work: raw,
			done: WorkerDone {
				completion: Arc::clone(&completion),
				outcome: WorkerOutcome::Unstarted,
			},
		}),
		retirement: Retirement {
			owner: Rc::clone(&owner),
			raw,
			completion,
			completed: false,
			reported: false,
		},
		_counted: Counted(Rc::clone(&owner)),
	};
	let host = Rc::clone(&owner.host);
	super::spawn_work(&owner.host, async move {
		let result = execute(custody).await;
		// The completion may settle a write or free a worker slot, so the
		// Host drains again through its one kick owner.
		host.schedule_kick_or_record();
		result
	})
}

/// Each submitted effect pays for one Tokio blocking job and one shared
/// retirement cell. The cell survives observer cancellation and joins physical
/// access. Omitting it would allow the C slot and backend to die during I/O.
/// Submitted payloads are borrowed, with no job-side byte copy.
async fn execute(mut custody: Custody) -> Result<()> {
	let Some(job) = custody.job.take() else {
		return Err(super::invalid("storage job already ran"));
	};
	let result = tokio::task::spawn_blocking(move || job.run()).await;
	let code = custody.retirement.complete();
	// Retirement::drop releases the Work and clears its diagnostic slot.
	// Capture the error before that boundary; recovery is a retained status.
	let completion = if code == ffi::GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED {
		Ok(())
	} else {
		check(code)
	};
	match result {
		Ok(outcome) => outcome?,
		Err(error) => return Err(super::invalid(&format!("storage worker failed: {error}"))),
	}
	completion
}

/// A physically retired worker still retains its owner when completion was
/// refused inside a callback. Retry at a normal finalizer boundary, and keep
/// both handles if the core still refuses ownership transfer.
pub(crate) fn finish_retired(owner: &Rc<AttachmentInner>, raw: *mut ffi::GlowcapLoamWork) -> bool {
	let mut completed = 0;
	// SAFETY: `raw` is the work handle `execute` parked via `park_loam_work`, whose worker `Retirement::drop` joined
	// before parking it, and the owner `Rc` keeps its attachment alive; `completed` is a local out-parameter the callee
	// writes.
	let code = unsafe { ffi::glowcap_loam_work_complete(raw, &mut completed) };
	if completed == 0 {
		return false;
	}
	if code != crate::sys::OK
		&& code != ffi::GLOWCAP_LOAM_ERR_STALE_COMPLETION
		&& code != ffi::GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED
		&& let Err(error) = check(code)
	{
		owner.host.record_background_failure(error);
	}
	// SAFETY: as the `glowcap_loam_work_complete` call above for `raw`, which `completed` shows the core took; the
	// release runs once, and a refusal returns `false` so the handle stays parked.
	if let Err(error) = check(unsafe { ffi::glowcap_loam_work_release(raw) }) {
		owner.host.record_background_failure(error);
		return false;
	}
	true
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::sync::atomic::{AtomicUsize, Ordering};

	#[test]
	fn queued_job_cancellation_retires_as_unstarted() {
		let runtime = tokio::runtime::Builder::new_current_thread()
			.max_blocking_threads(1)
			.enable_all()
			.build()
			.unwrap();
		runtime.block_on(async {
			let (started, ready) = std::sync::mpsc::channel();
			let (release, held) = std::sync::mpsc::channel();
			let blocker = tokio::task::spawn_blocking(move || {
				started.send(()).unwrap();
				held.recv().unwrap();
			});
			ready.recv().unwrap();
			let completion = Arc::new(Completion::default());
			let calls = Arc::new(AtomicUsize::new(0));
			let work_calls = Arc::clone(&calls);
			// The retirement token enters the queued closure before spawning,
			// so aborting a never-started job still releases its custody.
			let mut done = WorkerDone {
				completion: Arc::clone(&completion),
				outcome: WorkerOutcome::Unstarted,
			};
			let worker = tokio::task::spawn_blocking(move || {
				work_calls.fetch_add(1, Ordering::SeqCst);
				done.finish(crate::sys::OK);
			});
			worker.abort();
			release.send(()).unwrap();
			blocker.await.unwrap();
			assert!(worker.await.unwrap_err().is_cancelled());
			assert_eq!(calls.load(Ordering::SeqCst), 0);
			assert!(matches!(
				*completion.retired.lock().unwrap(),
				Some(WorkerOutcome::Unstarted)
			));
		});
	}
}
