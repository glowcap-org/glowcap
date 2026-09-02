//! Endpoint-barrier scenarios that cross the private runtime and the C seam.

use std::sync::Arc;

use crate::lifecycle::WriterTasks;
use crate::tests::direct_endpoint;
use crate::{glowcap_iroh_sidecar_endpoint_free, teardown_status, GlowcapIrohEndpoint};

#[test]
fn teardown_panics_become_failures() {
	assert_eq!(teardown_status(|| Ok(())), 0);
	assert_eq!(
		teardown_status(|| -> Result<(), ()> { panic!("forced teardown panic") }),
		-1
	);
}

#[test]
fn endpoint_release_is_safe_inside_an_ambient_tokio_runtime() {
	let endpoint = direct_endpoint(100);
	assert!(!endpoint.is_null());
	let raw = endpoint as usize;
	let ambient = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap();
	ambient.block_on(async move {
		assert_eq!(glowcap_iroh_sidecar_endpoint_free(raw as *mut GlowcapIrohEndpoint), 0);
	});
}

#[test]
fn detached_writer_failure_survives_until_endpoint_release() {
	let writers = Arc::new(WriterTasks::new());
	drop(writers.acquire());
	assert_eq!(writers.wait(), Err(()));
}
