//! Transport-provider package layout shared by standalone archives and the
//! optional native driver loop.

use core::ffi::{c_int, c_uchar, c_uint, c_void};

use super::layouts_gen::*;

#[repr(C)]
pub struct GlowcapTransportProvider {
	pub abi_version: c_uint,
	pub struct_size: usize,
	pub entries: *const c_void,
	pub entry_count: usize,
	pub lease_ctx: *mut c_void,
	pub same_configuration: Option<unsafe extern "C" fn(ctx: *mut c_void, other_ctx: *mut c_void) -> c_uchar>,
	pub retain: Option<unsafe extern "C" fn(ctx: *mut c_void) -> c_int>,
	pub release: Option<unsafe extern "C" fn(ctx: *mut c_void)>,
}

const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<GlowcapTransportProvider>() == GLOWCAP_TRANSPORT_PROVIDER_SIZE);
	assert!(offset_of!(GlowcapTransportProvider, abi_version) == GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION_OFF);
	assert!(offset_of!(GlowcapTransportProvider, struct_size) == GLOWCAP_TRANSPORT_PROVIDER_STRUCT_SIZE_OFF);
	assert!(offset_of!(GlowcapTransportProvider, entries) == GLOWCAP_TRANSPORT_PROVIDER_ENTRIES_OFF);
	assert!(offset_of!(GlowcapTransportProvider, entry_count) == GLOWCAP_TRANSPORT_PROVIDER_ENTRY_COUNT_OFF);
	assert!(offset_of!(GlowcapTransportProvider, lease_ctx) == GLOWCAP_TRANSPORT_PROVIDER_LEASE_CTX_OFF);
	assert!(
		offset_of!(GlowcapTransportProvider, same_configuration) == GLOWCAP_TRANSPORT_PROVIDER_SAME_CONFIGURATION_OFF
	);
	assert!(offset_of!(GlowcapTransportProvider, retain) == GLOWCAP_TRANSPORT_PROVIDER_RETAIN_OFF);
	assert!(offset_of!(GlowcapTransportProvider, release) == GLOWCAP_TRANSPORT_PROVIDER_RELEASE_OFF);
};
