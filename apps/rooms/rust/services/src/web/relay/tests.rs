use super::*;

#[test]
fn defaults_derive_from_the_http_fronts_connection_budget() {
	let limits = Limits::read(|_| None).unwrap();
	assert_eq!(limits.sessions, super::super::http::MAX_CONNECTIONS * 7 / 8);
	assert_eq!(limits.registrations, super::super::http::MAX_CONNECTIONS);
}

#[test]
fn tcp_admission_names_exact_endpoints_and_rejects_a_malformed_configuration() {
	let limits =
		Limits::read(|name| (name == "GLOWCAP_RELAY_TCP_PEERS").then(|| "127.0.0.1:9200,[::1]:9201".into())).unwrap();
	let (_, location) = watch::channel(Some(Announcement::new(
		"ocapn://127.0.0.2%3A9099.tcp".into(),
		None,
		Some(Endpoint::Tcp {
			host: "127.0.0.1".into(),
			port: 9099,
		}),
	)));
	let (jobs, _) = mpsc::channel(1);
	let (_, stop) = watch::channel(false);
	let relay = Relay::new(limits, location, jobs, stop);
	for target in ["127.0.0.1:9099", "127.0.0.2:9099", "127.0.0.1:9200", "[::1]:9201"] {
		assert!(matches!(relay.target(target), Ok(Target::Local(_))), "{target}");
	}
	for target in [
		"127.0.0.1:22",
		"10.0.0.8:9099",
		"127.0.0.1:9201",
		"[::1]:9200",
		"ocapn://abc.iroh",
		"https://example.com/",
	] {
		assert!(relay.target(target).is_err(), "{target}");
	}
	let key = "ab".repeat(32);
	assert!(matches!(
		relay.target(&format!("ocapn://{key}.iroh")),
		Ok(Target::Iroh(_))
	));
	assert!(
		relay
			.target(&format!("ocapn://{key}.keyed-tcp?direct-addresses=127.0.0.1:22"))
			.is_err()
	);
	assert!(
		Limits::read(|name| (name == "GLOWCAP_RELAY_TCP_PEERS").then(|| "127.0.0.1:9200,nonsense".into())).is_err()
	);
}

#[test]
fn origin_admission_refuses_foreign_and_opaque_browser_origins() {
	for (origin, allowed) in [
		(None, true),
		(Some("https://rooms.example"), true),
		(Some("https://elsewhere.example"), false),
		(Some("null"), false),
		(Some("garbage"), false),
	] {
		let mut request = Request::builder().header("host", "rooms.example");
		if let Some(origin) = origin {
			request = request.header("origin", origin);
		}
		assert_eq!(origin_allowed(&request.body(()).unwrap()), allowed, "{origin:?}");
	}
}
