use super::{limits::SITE_PAGE, *};

#[test]
fn defaults_derive_from_the_http_fronts_connection_budget() {
	let limits = Limits::read(|_| None).unwrap();
	assert_eq!(limits.sessions, super::super::http::MAX_CONNECTIONS * 7 / 8);
	assert_eq!(limits.registrations, super::super::http::MAX_CONNECTIONS);
}

#[test]
fn the_site_page_may_use_a_server_unless_other_pages_or_none_are_listed() {
	let limits = Limits::read(|_| None).unwrap();
	assert_eq!(limits.pages, vec![url::Url::parse(SITE_PAGE).unwrap()]);
	assert_eq!(limits.origins, vec![url::Url::parse(SITE_PAGE).unwrap().origin()]);
	let none = Limits::read(|name| (name == "GLOWCAP_RELAY_ALLOW_ORIGINS").then(String::new)).unwrap();
	assert!(none.pages.is_empty() && none.origins.is_empty());
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
	let (_, session) = watch::channel(None);
	let relay = Relay::new(limits, location, session, jobs, stop, Rc::new(|_| {}));
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
fn the_servers_own_shared_session_is_reached_by_key_or_relay_or_forwarded_tcp_and_not_by_onion() {
	assert!(matches!(
		session_reach(&format!("ocapn://{}.iroh/s/Ym9hcmQ", "ab".repeat(32))),
		Some(SessionReach::Direct)
	));
	assert!(matches!(
		session_reach(&format!(
			"ocapn://{}.noise-relay/s/Ym9hcmQ?rendezvous-relay=ws%3A%2F%2F127.0.0.1%3A8080%2Frelay",
			"ab".repeat(32)
		)),
		Some(SessionReach::Direct)
	));
	let Some(SessionReach::Forwarded(endpoint)) = session_reach("ocapn://127.0.0.1%3A9201.tcp/s/Ym9hcmQ") else {
		panic!("a tcp session is forwarded to");
	};
	assert_eq!(endpoint, Endpoint::tcp("127.0.0.1", 9201));
	// A session the relay cannot forward to is not offered to a browser.
	assert!(session_reach(&format!("ocapn://{}.onion/s/Ym9hcmQ", "a".repeat(56))).is_none());
	assert!(session_reach("not a link").is_none());
	let (_, location) = watch::channel(None);
	let (session, forwarding) = watch::channel(None);
	let (jobs, _) = mpsc::channel(1);
	let (_, stop) = watch::channel(false);
	let relay = Relay::new(
		Limits::read(|_| None).unwrap(),
		location,
		forwarding,
		jobs,
		stop,
		Rc::new(|_| {}),
	);
	// The browser asks for the link's locator, the session's own address,
	// which the relay forwards to once the session is open and not before.
	assert!(relay.target("ocapn://127.0.0.1%3A9201.tcp").is_err());
	session.send_replace(Some(endpoint));
	assert!(matches!(
		relay.target("ocapn://127.0.0.1%3A9201.tcp"),
		Ok(Target::Local(_))
	));
	assert!(relay.target("ocapn://127.0.0.1%3A9203.tcp").is_err());
}

#[test]
fn an_identity_route_location_owns_every_door_inside_it() {
	let key = "cd".repeat(32);
	let onion = format!("{}.onion", "b".repeat(56));
	let keyed = format!("ocapn://{key}.keyed-tcp?direct-addresses=127.0.0.1%3A9301");
	let route = rooms_glowcap::routes::identity_route(
		&key,
		&[
			"127.0.0.1:9301".to_owned(),
			keyed.clone(),
			format!("ocapn://{onion}"),
			format!("ocapn://{key}.noise-relay?rendezvous-relay=ws%3A%2F%2F127.0.0.1%3A8080%2Frelay"),
		],
	)
	.expect("four doors make a route");
	let announcement = Announcement::new(
		glowcap::format_locator_uri(&route).unwrap(),
		None,
		Some(Endpoint::tcp("127.0.0.1", 9301)),
	);
	let (_, location) = watch::channel(Some(announcement));
	let (jobs, _) = mpsc::channel(1);
	let (_, stop) = watch::channel(false);
	let (_, session) = watch::channel(None);
	let relay = Relay::new(
		Limits::read(|_| None).unwrap(),
		location,
		session,
		jobs,
		stop,
		Rc::new(|_| {}),
	);
	// The tcp fallback, the keyed tcp door, and the onion route all forward to
	// the local directory.
	assert!(matches!(relay.target("127.0.0.1:9301"), Ok(Target::Local(_))));
	assert!(matches!(relay.target(&keyed), Ok(Target::Local(_))));
	assert!(matches!(
		relay.target(&format!("ocapn://{onion}")),
		Ok(Target::Local(_))
	));
	// A foreign onion and an unlisted tcp address stay refused.
	assert!(relay.target(&format!("ocapn://{}.onion", "c".repeat(56))).is_err());
	assert!(relay.target("127.0.0.1:9302").is_err());
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
		assert_eq!(origin_allowed(&request.body(()).unwrap(), &[]), allowed, "{origin:?}");
	}
}

#[test]
fn a_listed_page_origin_may_relay_and_nothing_near_it_may() {
	let limits = Limits::read(|name| {
		(name == "GLOWCAP_RELAY_ALLOW_ORIGINS").then(|| "https://pages.example/, http://127.0.0.1:8093".into())
	})
	.unwrap();
	for (origin, allowed) in [
		("https://pages.example", true),
		("http://127.0.0.1:8093", true),
		("https://rooms.example", true),
		("http://pages.example", false),
		("https://pages.example:8443", false),
		("https://sub.pages.example", false),
		("null", false),
	] {
		let request = Request::builder()
			.header("host", "rooms.example")
			.header("origin", origin)
			.body(())
			.unwrap();
		assert_eq!(origin_allowed(&request, &limits.origins), allowed, "{origin}");
	}
	// A read such as `locator` names only a listed origin back, never this
	// server's own (which needs no header) or one near a listed one.
	let (_, location) = watch::channel(None);
	let (jobs, _) = mpsc::channel(1);
	let (_, stop) = watch::channel(false);
	let (_, session) = watch::channel(None);
	let relay = Relay::new(limits, location, session, jobs, stop, Rc::new(|_| {}));
	for (origin, named) in [
		("https://pages.example", true),
		("http://127.0.0.1:8093", true),
		("https://rooms.example", false),
		("https://pages.example:8443", false),
		("null", false),
	] {
		let request = Request::builder().header("origin", origin).body(()).unwrap();
		let answer = relay.listed_origin(&request);
		assert_eq!(answer.is_some(), named, "{origin}");
		assert!(answer.is_none_or(|value| value == origin), "{origin}");
	}
	assert!(relay.listed_origin(&Request::builder().body(()).unwrap()).is_none());
}

#[test]
fn a_refused_page_origin_is_told_to_the_operator_with_the_option_that_admits_it() {
	let limits = Limits::read(|_| None).unwrap();
	let (_, location) = watch::channel(None);
	let (jobs, _) = mpsc::channel(1);
	let (_, stop) = watch::channel(false);
	let told = Rc::new(std::cell::RefCell::new(Vec::new()));
	let sink = told.clone();
	let (_, session) = watch::channel(None);
	let relay = Relay::new(
		limits,
		location,
		session,
		jobs,
		stop,
		Rc::new(move |notice| sink.borrow_mut().push(notice.to_string())),
	);
	let page = |origin: &str| {
		Request::builder()
			.header("host", "127.0.0.1:19080")
			.header("origin", origin)
			.body(())
			.unwrap()
	};
	assert!(relay.admits(&page("http://127.0.0.1:19080")));
	for _ in 0..3 {
		assert!(!relay.admits(&page("http://localhost:16173")));
	}
	assert!(!relay.admits(&page("null")));
	assert_eq!(
		*told.borrow(),
		[
			"refused a Rooms page from http://localhost:16173. To let it in, start with --allow-origin=https://glowcap.org/rooms/app/,http://localhost:16173",
			"refused a Rooms page from http://localhost:16173. To let it in, start with --allow-origin=https://glowcap.org/rooms/app/,http://localhost:16173 (2 times in a row)",
			"refused a Rooms page from \"null\", which is not an origin the option takes",
		]
	);
	for entry in [
		"pages.example",
		"https://pages.example/rooms",
		"https://pages.example?x",
		"ftp://pages.example",
		"null",
	] {
		assert!(
			Limits::read(|name| (name == "GLOWCAP_RELAY_ALLOW_ORIGINS").then(|| entry.into())).is_err(),
			"{entry}"
		);
	}
}
