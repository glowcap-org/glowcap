//! Storage jobs borrow storage work until the blocking worker actually retires.
use super::{AttachmentInner, check};
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
/// The C companion permits exactly this effect to run off-thread. It accesses
/// immutable submitted buffers and backend state, never Host callbacks or turns.
/// The owner-thread retirement guard keeps both owners alive and joins all
/// accesses before portable completion. No application capability crosses here.
struct StorageJob {
	storage: *mut ffi::GlowcapLoamLmdb,
	work: *mut ffi::GlowcapLoamWork,
	done: WorkerDone,
}
// SAFETY: the exclusive work handle and retained backend satisfy the C worker
// contract above. Only its result is written; Host installation stays local.
unsafe impl Send for StorageJob {}
impl StorageJob {
	fn run(mut self) -> Result<()> {
		let code = unsafe { ffi::glowcap_loam_lmdb_work_run(self.storage, self.work) };
		self.done.finish(code);
		check(code, true)
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
				let code = unsafe { ffi::glowcap_loam_work_report_unstarted(self.raw) };
				if code != crate::sys::OK {
					return code;
				}
			}
			self.reported = true;
		}
		let mut completed = 0;
		let code = unsafe { ffi::glowcap_loam_work_complete(self.raw, &mut completed) };
		self.completed = completed != 0;
		code
	}
}
impl Drop for Retirement {
	fn drop(&mut self) {
		// Dropping an observer cannot free an active LMDB worker's buffers.
		// A cancelled progress future joins before installation and release.
		if !self.completed {
			let rc = self.complete();
			if self.completed
				&& rc != ffi::GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED
				&& let Err(error) = check(rc, false)
			{
				self.owner.host.record_background_failure(error);
			}
		}
		if !self.completed {
			crate::finalizer::park_loam_work(Rc::clone(&self.owner), self.raw);
			self.owner.host.schedule_kick_or_record();
		} else if let Err(error) = check(unsafe { ffi::glowcap_loam_work_release(self.raw) }, false) {
			self.owner.host.record_background_failure(error);
			crate::finalizer::park_loam_work(Rc::clone(&self.owner), self.raw);
		}
	}
}
/// Each submitted effect pays for one Tokio blocking job and one shared
/// retirement cell. The cell survives observer cancellation and joins physical
/// access; omitting it would allow the C slot and backend to die during I/O.
/// Submitted payloads are borrowed, with no job-side byte copy.
pub(super) async fn execute(owner: Rc<AttachmentInner>, raw: *mut ffi::GlowcapLoamWork) -> Result<i32> {
	let completion = Arc::new(Completion::default());
	let job = StorageJob {
		storage: owner.store.storage.get(),
		work: raw,
		done: WorkerDone {
			completion: Arc::clone(&completion),
			outcome: WorkerOutcome::Unstarted,
		},
	};
	let mut retirement = Retirement {
		owner,
		raw,
		completion,
		completed: false,
		reported: false,
	};
	let result = tokio::task::spawn_blocking(move || job.run()).await;
	let code = retirement.complete();
	match result {
		Ok(outcome) => outcome?,
		Err(error) => return Err(super::invalid(&format!("storage worker failed: {error}"))),
	}
	Ok(code)
}

/// A physically retired worker still retains its owner when completion was
/// refused inside a callback. Retry at a normal finalizer boundary, and keep
/// both handles if the core still refuses ownership transfer.
pub(crate) fn finish_retired(owner: &Rc<AttachmentInner>, raw: *mut ffi::GlowcapLoamWork) -> bool {
	let mut completed = 0;
	let code = unsafe { ffi::glowcap_loam_work_complete(raw, &mut completed) };
	if completed == 0 {
		return false;
	}
	if code != crate::sys::OK
		&& code != ffi::GLOWCAP_LOAM_ERR_STALE_COMPLETION
		&& code != ffi::GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED
		&& let Err(error) = check(code, false)
	{
		owner.host.record_background_failure(error);
	}
	if let Err(error) = check(unsafe { ffi::glowcap_loam_work_release(raw) }, false) {
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
