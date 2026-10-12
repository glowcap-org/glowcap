use super::*;

fn text_view(text: &str) -> GlowcapWebrtcStringView {
	GlowcapWebrtcStringView {
		ptr: text.as_ptr(),
		len: text.len(),
	}
}

fn bytes_view(bytes: &[u8]) -> GlowcapWebrtcStringView {
	GlowcapWebrtcStringView {
		ptr: bytes.as_ptr(),
		len: bytes.len(),
	}
}

fn no_text() -> GlowcapWebrtcStringView {
	GlowcapWebrtcStringView {
		ptr: std::ptr::null(),
		len: 0,
	}
}

fn endpoint_config(servers: &[GlowcapWebrtcIceServer]) -> GlowcapWebrtcEndpointConfig {
	GlowcapWebrtcEndpointConfig {
		ice_servers: servers.as_ptr(),
		ice_server_count: servers.len(),
		include_loopback_candidates: 0,
		worker_threads: 0,
	}
}

fn endpoint_refuses(servers: &[GlowcapWebrtcIceServer]) {
	assert!(test_endpoint_new(&endpoint_config(servers)).is_null());
}

fn ice_server(
	urls: &[GlowcapWebrtcStringView],
	username: GlowcapWebrtcStringView,
	credential: GlowcapWebrtcStringView,
) -> GlowcapWebrtcIceServer {
	GlowcapWebrtcIceServer {
		urls: urls.as_ptr(),
		url_count: urls.len(),
		username,
		credential,
	}
}

/// The ICE servers a caller names reach the endpoint, and a caller that
/// names none still gets one.
///
/// A live STUN server cannot be reached from a hermetic test, so what this
/// holds is the seam rather than the traversal: URL and credential views are
/// copied into endpoint-owned WebRTC records every peer is built from.
#[test]
fn ice_servers_reach_the_endpoint() {
	let stun_urls = [text_view("stun:stun.example:3478")];
	let turn_urls = [
		text_view("turn:turn.example:3478"),
		text_view("turns:turn.example:5349"),
	];
	let servers = [
		GlowcapWebrtcIceServer {
			urls: stun_urls.as_ptr(),
			url_count: stun_urls.len(),
			username: text_view(""),
			credential: text_view(""),
		},
		GlowcapWebrtcIceServer {
			urls: turn_urls.as_ptr(),
			url_count: turn_urls.len(),
			username: text_view("user"),
			credential: text_view("pass"),
		},
	];
	let cfg = GlowcapWebrtcEndpointConfig {
		ice_servers: servers.as_ptr(),
		ice_server_count: servers.len(),
		include_loopback_candidates: 0,
		worker_threads: 0,
	};
	let ep = test_endpoint_new(&cfg);
	assert!(!ep.is_null());
	assert_eq!(
		// SAFETY: `ep` is the non-null live handle `test_endpoint_new` returned (asserted above); only the
		// `glowcap_webrtc_sidecar_endpoint_free` call below frees it, after this borrow ends.
		unsafe { &*ep }.inner.ice_servers,
		vec![
			RTCIceServer {
				urls: vec!["stun:stun.example:3478".to_string()],
				username: String::new(),
				credential: String::new(),
			},
			RTCIceServer {
				urls: vec![
					"turn:turn.example:3478".to_string(),
					"turns:turn.example:5349".to_string(),
				],
				username: "user".to_string(),
				credential: "pass".to_string(),
			}
		]
	);
	// SAFETY: `ep` is the owned endpoint handle `test_endpoint_new` returned; nothing has freed it, it has no peers,
	// and it is not used after this call.
	unsafe { glowcap_webrtc_sidecar_endpoint_free(ep) };

	let empty = GlowcapWebrtcEndpointConfig {
		ice_servers: std::ptr::null(),
		ice_server_count: 0,
		include_loopback_candidates: 0,
		worker_threads: 0,
	};
	let host_only = test_endpoint_new(&empty);
	assert!(!host_only.is_null());
	// SAFETY: `host_only` is the non-null live handle `test_endpoint_new` returned (asserted above); only the
	// `glowcap_webrtc_sidecar_endpoint_free` call below frees it, after this borrow ends.
	assert!(unsafe { &*host_only }.inner.ice_servers.is_empty());
	// SAFETY: `host_only` is the owned endpoint handle `test_endpoint_new` returned; nothing has freed it, it has no
	// peers, and it is not used after this call.
	unsafe { glowcap_webrtc_sidecar_endpoint_free(host_only) };
}

/// A null config is refused rather than silently taken as "no ICE servers",
/// so a caller that forgot to pass one finds out here instead of in a
/// deployment where nothing can traverse NAT.
#[test]
fn a_null_config_is_refused() {
	assert!(test_endpoint_new(std::ptr::null()).is_null());
}

#[test]
fn sidecar_endpoint_bounds_ice_server_records_before_creation() {
	let urls = [text_view("stun:stun.example:3478")];
	let server = ice_server(&urls, no_text(), no_text());
	let servers = [server; MAX_ICE_SERVERS + 1];

	endpoint_refuses(&servers);
}

#[test]
fn sidecar_endpoint_bounds_nested_ice_url_records_before_creation() {
	let urls = [text_view("stun:stun.example:3478"); MAX_ICE_URLS_PER_SERVER + 1];
	let servers = [ice_server(&urls, no_text(), no_text())];

	endpoint_refuses(&servers);
}

#[test]
fn sidecar_endpoint_rejects_invalid_ice_url_shapes() {
	let oversized = "s".repeat(MAX_ICE_URL_BYTES + 1);
	let invalid_utf8 = [0xff];
	let bad_scheme = [text_view("https://issuer.example/ice")];
	let cases = [
		[text_view("")],
		[text_view(&oversized)],
		[bytes_view(&invalid_utf8)],
		bad_scheme,
	];

	for urls in cases {
		endpoint_refuses(&[ice_server(&urls, no_text(), no_text())]);
	}
}

#[test]
fn sidecar_endpoint_rejects_invalid_ice_credential_shapes() {
	let stun = [text_view("stun:stun.example:3478")];
	let turn = [text_view("turn:turn.example:3478")];
	let oversized = "c".repeat(MAX_ICE_CREDENTIAL_BYTES + 1);
	let invalid_utf8 = [0xff];
	let cases = [
		ice_server(&stun, text_view("user"), no_text()),
		ice_server(&turn, no_text(), no_text()),
		ice_server(&turn, text_view("user"), text_view(&oversized)),
		ice_server(&turn, bytes_view(&invalid_utf8), text_view("pass")),
	];

	for server in cases {
		endpoint_refuses(&[server]);
	}
}
