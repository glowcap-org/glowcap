//! Consumed failures preserve their code and never reach C again.
use super::*;
use crate::ErrorKind;
use std::sync::{
	Arc, Mutex,
	atomic::{AtomicUsize, Ordering},
};

/// An executor whose release answers from a script and that counts every call
/// reaching the engine.
struct Scripted {
	releases: Mutex<Vec<i32>>,
	calls: AtomicUsize,
	released: AtomicUsize,
}
impl Scripted {
	fn new(mut releases: Vec<i32>) -> Arc<Self> {
		releases.reverse();
		Arc::new(Self {
			releases: Mutex::new(releases),
			calls: AtomicUsize::new(0),
			released: AtomicUsize::new(0),
		})
	}
	fn touch(&self) -> i32 {
		self.calls.fetch_add(1, Ordering::SeqCst);
		crate::sys::OK
	}
}
impl Executor for Scripted {
	fn work_run(&self, _work: *mut ffi::GlowcapLoamWork) -> i32 {
		self.touch()
	}
	fn restore(
		&self,
		_attachment: *mut ffi::GlowcapLoamAttachment,
		_object: *const ffi::GlowcapLoamObject,
		_out_ref: *mut crate::sys::GlowcapReference,
	) -> i32 {
		self.touch()
	}
	fn commit(&self) -> i32 {
		self.touch()
	}
	fn collect(&self, _work_limit: usize) -> i32 {
		self.touch()
	}
	fn recover(&self) -> i32 {
		self.touch()
	}
	fn release(&self) -> i32 {
		self.calls.fetch_add(1, Ordering::SeqCst);
		self.released.fetch_add(1, Ordering::SeqCst);
		self.releases
			.lock()
			.unwrap()
			.pop()
			.expect("release called past its script")
	}
	fn last_error(&self, buf: &mut [u8]) -> usize {
		let detail = b"engine close failed";
		let len = detail.len().min(buf.len());
		buf[..len].copy_from_slice(&detail[..len]);
		len
	}
}

fn scripted_store(executor: &Arc<Scripted>) -> Store {
	let executor: Arc<dyn Executor> = executor.clone();
	Store {
		inner: Rc::new(StoreInner {
			executor,
			released: Cell::new(false),
			store: core::ptr::null_mut(),
			pending_creation: RefCell::new(Some(Resource {
				raw: ffi::GlowcapLoamResource {
					owner: ffi::GlowcapLoamObject { key: [1; 33] },
					r#use: ffi::GlowcapLoamObject { key: [2; 33] },
					control: ffi::GlowcapLoamObject { key: [3; 33] },
				},
			})),
		}),
	}
}

#[test]
fn an_engine_close_failure_consumes_the_store_and_names_its_cause() {
	let executor = Scripted::new(vec![-crate::sys::ERR_IO]);
	let mut store = scripted_store(&executor);
	let error = store.close().expect_err("the engine close failure reaches the caller");
	assert_eq!(error.kind(), ErrorKind::Io);
	assert!(error.to_string().contains("engine close failed"), "{error}");
	store.close().expect("a consumed store is already closed");
	let calls = executor.calls.load(Ordering::SeqCst);
	assert!(store.collect(1).is_err(), "collect on a released store refuses");
	assert!(
		store.recover_creation().is_err(),
		"recovery on a released store refuses"
	);
	assert_eq!(
		executor.calls.load(Ordering::SeqCst),
		calls,
		"no call reaches the freed handle"
	);
	drop(store);
	crate::finalizer::drain();
	assert_eq!(
		executor.released.load(Ordering::SeqCst),
		1,
		"a consumed handle is released once"
	);
}

#[test]
fn a_dropped_store_whose_engine_close_fails_is_not_retried() {
	let executor = Scripted::new(vec![-crate::sys::ERR_IO]);
	let parked = crate::finalizer::pending_count();
	drop(scripted_store(&executor));
	assert_eq!(
		crate::finalizer::pending_count(),
		parked,
		"a consumed handle is not parked"
	);
	crate::finalizer::drain();
	assert_eq!(executor.released.load(Ordering::SeqCst), 1);
}

#[test]
fn a_refused_release_keeps_the_store_for_a_retry() {
	let executor = Scripted::new(vec![crate::sys::WOULD_BLOCK, crate::sys::OK]);
	let mut store = scripted_store(&executor);
	assert!(store.close().is_err(), "Busy refuses");
	store.close().expect("the kept handle releases on retry");
	assert_eq!(executor.released.load(Ordering::SeqCst), 2);
}

#[test]
fn a_parked_store_whose_engine_close_fails_is_released_once() {
	let executor = Scripted::new(vec![crate::sys::WOULD_BLOCK, -crate::sys::WOULD_BLOCK]);
	let parked = crate::finalizer::pending_count();
	drop(scripted_store(&executor));
	assert_eq!(
		crate::finalizer::pending_count(),
		parked + 1,
		"a refused handle is parked"
	);
	crate::finalizer::drain();
	assert_eq!(
		crate::finalizer::pending_count(),
		parked,
		"a consumed handle leaves the queue"
	);
	crate::finalizer::drain();
	assert_eq!(executor.released.load(Ordering::SeqCst), 2);
}
