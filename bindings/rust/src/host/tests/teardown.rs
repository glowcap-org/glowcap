//! A caller's TLS owner may outlive the binding's trace registry.
use super::*;
use std::cell::RefCell;

#[test]
fn host_release_after_trace_registry_teardown() {
	std::thread::spawn(|| {
		thread_local! {
			static OWNER: RefCell<Option<Host>> = const { RefCell::new(None) };
		}
		// Register this destructor first. Host construction then registers the
		// trace registry, whose destructor runs before the caller releases Host.
		OWNER.with(|owner| assert!(owner.borrow().is_none()));
		let host = Host::new_host();
		OWNER.with(|owner| *owner.borrow_mut() = Some(host));
	})
	.join()
	.unwrap();
}
