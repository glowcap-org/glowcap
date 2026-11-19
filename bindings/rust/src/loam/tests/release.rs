//! Release outcomes and retained ownership across Loam and its driver Host.
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

#[test]
fn a_refused_driver_keeps_its_context_until_the_finalizer_consumes_it() {
	let store = Store::open(
		Volatile {
			identity: [3; 16],
			capacity_bytes: 8 * 1024 * 1024,
		},
		&[SCHEMA],
		Limits::default(),
	)
	.unwrap();
	let context = crate::Context::new().unwrap();
	let reader = Rc::downgrade(&context.inner);
	let driver = crate::driver_loop::DriverLoop::open(&context, &[0x31; 64], Default::default()).unwrap();
	let mut host_id = 0;
	// SAFETY: the driver owns this live Host and the ID is a local out-slot.
	crate::host::check_host(unsafe { crate::sys::host::glowcap_host_diagnostic_id(driver.host(), &mut host_id) })
		.unwrap();
	let prepared = registration::Prepared::new(vec![registration()], context.retain_inner(), host_id);
	let mut attachment = core::ptr::null_mut();
	check(
		// SAFETY: the store and driver Host are live. The declarations and their callbacks
		// remain live in prepared through attachment release. Entropy takes no user state.
		unsafe {
			ffi::glowcap_loam_attach(
				store.inner.store,
				driver.host(),
				prepared.declarations.as_ptr(),
				prepared.declarations.len(),
				Some(content::entropy),
				core::ptr::null_mut(),
				&mut attachment,
			)
		},
	)
	.unwrap();
	let before = crate::finalizer::pending_count();
	drop(driver);
	let first = context.next_failure().unwrap();
	let second = context.next_failure().unwrap();
	drop(context);
	assert_eq!(crate::finalizer::pending_count(), before + 1);
	crate::finalizer::drain();
	assert_eq!(crate::finalizer::pending_count(), before + 1);

	assert_eq!(
		// SAFETY: the attachment still owns its borrow of the parked Host. This is its only release.
		unsafe { ffi::glowcap_loam_attachment_release(attachment) },
		crate::sys::OK
	);
	drop(prepared);
	assert!(
		reader.upgrade().is_some(),
		"the finalizer owns the last Context reference"
	);
	crate::finalizer::drain();
	assert_eq!(crate::finalizer::pending_count(), before);
	assert!(reader.upgrade().is_none());
	let refusal = first.expect("the driver drop reports its refusal to the caller's Context");
	assert_eq!(refusal.layer, crate::FailureLayer::Driver);
	assert_eq!(refusal.scope, crate::FailureScope::Context);
	assert_eq!(refusal.operation, "driver-loop-drop-release");
	assert_eq!(refusal.primary_result, crate::sys::ERR_INVALID_ARGUMENT);
	assert!(second.is_none());
}
