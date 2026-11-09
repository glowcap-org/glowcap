use super::{BrowserAssets, Config, PeerEnvironment, listener_relay, own_relay};
use std::path::Path;

fn parse(args: &[&str]) -> Config {
	Config::parse(args.iter().map(|arg| (*arg).to_owned()), |_| None)
		.unwrap()
		.unwrap()
}

#[test]
fn http_policy_stays_at_its_owner_and_arguments_override_environment() {
	let config = Config::parse(
		[
			"--http-admission-rates=preview=2/10".into(),
			"--http-admission-per-address=true".into(),
		],
		|key| (key == "GLOWCAP_ROOMS_HTTP_ADMISSION_RATES").then(|| "preview=1/1".into()),
	)
	.unwrap()
	.unwrap();
	assert_eq!(
		config
			.admission
			.settings
			.profile()
			.rate(rooms_application::admission::Class::Preview)
			.burst(),
		2
	);
	assert!(config.admission.per_address);
	assert!(!config.server_args.iter().any(|s| s.starts_with("--http-admission")));
	assert!(config.admission.settings.summary().contains("admission-rates=argument"));
	assert!(Config::parse(["--http-admission-rows=0".into()], |_| None).is_err());
}

#[test]
fn the_front_hands_its_peers_the_public_relay_only_at_its_own() {
	let public = url::Url::parse("http://localhost:19080/").unwrap();
	let own = own_relay("ws://127.0.0.1:8080/relay".into(), Some(&public));
	assert_eq!(
		(own.reach.as_str(), own.public()),
		("ws://127.0.0.1:8080/relay", Some("ws://localhost:19080/relay"))
	);
	assert_eq!(own_relay("ws://127.0.0.1:8080/relay".into(), None).public(), None);
	let named = listener_relay(Some("wss://relay.example/relay"), own.clone());
	assert_eq!(listener_relay(None, own.clone()), own);
	assert_eq!(
		(named.reach.as_str(), named.public()),
		("wss://relay.example/relay", None)
	);
	// A peer reads what the front hands first, then its environment.
	let handed = PeerEnvironment {
		relay: named,
		tor: None,
	};
	let env = |key: &str| (key == "GLOWCAP_ROOMS_RELAY_PUBLIC_URL").then(|| "wss://ops.example/relay".to_owned());
	assert_eq!(
		handed.read(env, "GLOWCAP_ROOMS_RELAY_URL").as_deref(),
		Some("wss://relay.example/relay")
	);
	assert_eq!(
		handed.read(env, "GLOWCAP_ROOMS_RELAY_PUBLIC_URL").as_deref(),
		Some("wss://ops.example/relay")
	);
	assert_eq!(handed.read(env, "GLOWCAP_ONION_SOCKS"), None);
}
#[test]
fn the_shared_sessions_options_pass_in_its_grammar_and_need_its_state() {
	let config = Config::parse(
		[
			"--session-state=/tmp/s".into(),
			"--session-transport=noise-relay".into(),
			"--session-relay=wss://relay.example/relay".into(),
			"--session-relay-public=wss://rooms.example/relay".into(),
		],
		|_| None,
	)
	.unwrap()
	.unwrap();
	assert_eq!(
		config.session.unwrap().args,
		[
			"--relay=wss://relay.example/relay",
			"--relay-public=wss://rooms.example/relay",
			"--state=/tmp/s",
			"--transport=noise-relay"
		]
	);
	assert!(!config.server_args.iter().any(|arg| arg.contains("session")));
	assert_eq!(
		Config::parse(["--session-transport=tcp".into()], |_| None)
			.err()
			.unwrap(),
		"the shared session's options need --session-state=<directory> or GLOWCAP_ROOMS_SESSION_STATE"
	);
	assert_eq!(
		Config::parse(
			["--session-state=/tmp/s".into(), "--session-colour=blue".into()],
			|_| None
		)
		.err()
		.unwrap(),
		"unknown option: --session-colour"
	);
	// The session's own refusals come through as they are.
	assert!(
		Config::parse(
			["--session-state=/tmp/s".into(), "--session-transport=zeppelin".into()],
			|_| None
		)
		.err()
		.unwrap()
		.contains("session transport must be one of")
	);
	// An onion door on the session alone plans a private Tor, which the
	// front hands the session and never writes into the directory's arguments.
	let onion = Config::parse(
		["--session-state=/tmp/s".into(), "--session-transport=onion".into()],
		|_| None,
	)
	.unwrap()
	.unwrap();
	assert!(onion.tor.is_some());
	assert!(onion.server_args.iter().all(|arg| !arg.starts_with("--onion-")));
}
#[test]
fn a_public_address_for_this_servers_own_relay_is_refused() {
	let refused = |args: &[&str]| {
		Config::parse(args.iter().map(|arg| (*arg).to_owned()), |_| None)
			.err()
			.expect("a refusal")
	};
	let message = |option: &str| {
		format!(
			"{option} names how peers dial the relay named with it; this server's own relay is dialed at --http-public"
		)
	};
	assert_eq!(
		refused(&["--transport=noise-relay", "--relay-public=wss://rooms.example/relay"]),
		message("--relay-public")
	);
	assert_eq!(
		refused(&[
			"--session-state=/tmp/s",
			"--session-transport=noise-relay",
			"--session-relay-public=wss://rooms.example/relay",
		]),
		message("--session-relay-public")
	);
	// Naming the relay the peer registers at takes its public address too,
	// as an option or as the environment every peer under this front reads.
	let named = parse(&[
		"--transport=noise-relay",
		"--relay=wss://relay.example/relay",
		"--relay-public=wss://rooms.example/relay",
	]);
	assert!(
		named
			.server_args
			.contains(&"--relay-public=wss://rooms.example/relay".to_owned())
	);
	let environment = Config::parse(
		[
			"--transport=noise-relay".into(),
			"--relay-public=wss://rooms.example/relay".into(),
		],
		|key| (key == "GLOWCAP_ROOMS_RELAY_URL").then(|| "wss://relay.example/relay".into()),
	)
	.unwrap()
	.unwrap();
	assert_eq!(environment.relay_url.as_deref(), Some("wss://relay.example/relay"));
}

#[test]
fn every_listen_declaration_reaches_the_directory() {
	let config = parse(&["--listen=noise-relay", "--transport=tcp", "--listen=noise-tcp,port=0"]);
	let declared: Vec<_> = config
		.server_args
		.iter()
		.filter(|arg| arg.starts_with("--listen="))
		.collect();
	assert_eq!(declared, ["--listen=noise-relay", "--listen=noise-tcp,port=0"]);
	assert_eq!(config.room.listen.len(), 2);
	assert!(config.relay_url.is_none());
	let refused = |args: &[&str]| {
		Config::parse(args.iter().map(|arg| (*arg).to_owned()), |_| None)
			.err()
			.expect("a refusal")
	};
	assert_eq!(
		refused(&["--listen"]),
		"--listen needs a value, as in --listen=<transport>[,<name>=<value>...]"
	);
	assert!(refused(&["--listen=iroh"]).contains("names the announced transport"));
	// A relay transport for the directory itself needs no relay named:
	// it registers at this server's own.
	let config = parse(&["--transport=noise-relay"]);
	assert!(config.server_args.contains(&"--transport=noise-relay".to_owned()));
	assert!(matches!(
		config.room.transport,
		rooms_platform::serving::Transport::Relay { .. }
	));
	let config = Config::parse([], |key| {
		(key == "GLOWCAP_ROOMS_RELAY_URL").then(|| " wss://relay.example/relay ".into())
	})
	.unwrap()
	.unwrap();
	assert_eq!(config.relay_url.as_deref(), Some("wss://relay.example/relay"));
}

#[test]
fn allowed_origins_come_from_the_option_over_the_environment_and_stay_out_of_server_args() {
	let env = |key: &str| (key == "GLOWCAP_RELAY_ALLOW_ORIGINS").then(|| "https://env.example".into());
	let config = Config::parse(["--allow-origin=https://glowcap.org,http://127.0.0.1:8093".into()], env)
		.unwrap()
		.unwrap();
	let origins: Vec<_> = config
		.relay
		.origins
		.iter()
		.map(|origin| origin.ascii_serialization())
		.collect();
	assert_eq!(origins, ["https://glowcap.org", "http://127.0.0.1:8093"]);
	assert!(!config.server_args.iter().any(|s| s.contains("allow-origin")));
	let config = Config::parse([], env).unwrap().unwrap();
	assert_eq!(config.relay.origins.len(), 1);
	// The empty value the help names: no page but this server's own.
	let config = Config::parse(["--allow-origin=".into()], env).unwrap().unwrap();
	assert!(config.relay.origins.is_empty() && config.relay.pages.is_empty());
	assert_eq!(
		Config::parse(["--allow-origin".into()], |_| None).err().unwrap(),
		"--allow-origin needs a value, as in --allow-origin=<origin|page,...>"
	);
	assert_eq!(
		Config::parse(["--session-state".into()], |_| None).err().unwrap(),
		"--session-state needs a value, as in --session-state=<directory>"
	);
	// A page's own address admits its origin, and is the page the banner
	// links to. A path without its final `/` names no page exactly.
	let config = Config::parse(
		["--allow-origin=https://glowcap.org/rooms/app/,http://127.0.0.1:8093".into()],
		|_| None,
	)
	.unwrap()
	.unwrap();
	assert_eq!(config.relay.origins.len(), 2);
	assert_eq!(config.relay.origins[0].ascii_serialization(), "https://glowcap.org");
	let pages: Vec<_> = config.relay.pages.iter().map(url::Url::as_str).collect();
	assert_eq!(pages, ["https://glowcap.org/rooms/app/"]);
	// The option repeated keeps every value, in order, the same as one list.
	let repeated = Config::parse(
		[
			"--allow-origin=https://glowcap.org/rooms/app/".into(),
			"--allow-origin=http://127.0.0.1:8093".into(),
		],
		|_| None,
	)
	.unwrap()
	.unwrap();
	assert_eq!(repeated.relay.origins, config.relay.origins);
	assert_eq!(repeated.relay.pages, config.relay.pages);
	// An empty value among others adds nothing, and alone it allows none.
	for mixed in [
		["--allow-origin=", "--allow-origin=http://127.0.0.1:8093"],
		["--allow-origin=http://127.0.0.1:8093", "--allow-origin="],
	] {
		assert_eq!(parse(&mixed).relay.origins.len(), 1, "{mixed:?}");
	}
	assert!(Config::parse(["--allow-origin=https://glowcap.org/rooms/app".into()], |_| None).is_err());
	// A page at the root of its origin is written with its `/`, and a bare
	// origin without one, so the two are told apart as written.
	let config = Config::parse(
		["--allow-origin=https://pages.example/,https://origin.example".into()],
		|_| None,
	)
	.unwrap()
	.unwrap();
	let pages: Vec<_> = config.relay.pages.iter().map(url::Url::as_str).collect();
	assert_eq!(pages, ["https://pages.example/"]);
	assert_eq!(
		config.relay.listed,
		["https://pages.example/", "https://origin.example"]
	);
}

#[test]
fn every_other_option_is_given_once_and_a_port_is_named_one_way() {
	let refused = |args: &[&str]| {
		Config::parse(args.iter().map(|arg| (*arg).to_owned()), |_| None)
			.err()
			.unwrap()
	};
	assert_eq!(
		refused(&["--http-port=8081", "--http-port=8082"]),
		"repeated option: --http-port"
	);
	assert_eq!(
		refused(&["--transport=iroh", "--transport=tcp"]),
		"repeated option: --transport"
	);
	assert_eq!(
		refused(&["--capabilities=operator", "--capabilities=irc"]),
		"repeated option: --capabilities"
	);
	assert_eq!(
		refused(&["8081", "--http-port=8081"]),
		"the HTTP port is given twice, as --http-port and as the first positional argument"
	);
	assert_eq!(
		refused(&["8081", "9100", "--port=9100"]),
		"the room port is given twice, as --port and as the second positional argument"
	);
	// The environment supplies a default the argument replaces, never a
	// second value, so a launcher's choice and a person's coexist.
	let env = |key: &str| (key == "GLOWCAP_ROOMS_TRANSPORT").then(|| "iroh".into());
	let config = Config::parse(["--transport=tcp".into()], env).unwrap().unwrap();
	assert!(config.server_args.contains(&"--transport=tcp".to_owned()));
}

#[test]
fn the_session_workspace_is_read_from_the_argument_or_the_environment() {
	let env = |key: &str| (key == "GLOWCAP_ROOMS_SESSION_STATE").then(|| "/tmp/env-session".into());
	assert!(Config::parse([], env).unwrap().unwrap().session.is_some());
	assert!(Config::parse([], |_| None).unwrap().unwrap().session.is_none());
	let config = Config::parse(["--session-state=/tmp/arg-session".into()], env)
		.unwrap()
		.unwrap();
	assert_eq!(config.session.unwrap().args, ["--state=/tmp/arg-session"]);
}

#[test]
fn the_public_address_is_read_exactly_from_arguments_or_environment_and_stays_out_of_server_args() {
	let config = Config::parse(["--http-public=https://rooms.example/".into()], |_| None)
		.unwrap()
		.unwrap();
	assert_eq!(
		config.public.as_ref().map(url::Url::as_str),
		Some("https://rooms.example/")
	);
	assert!(!config.server_args.iter().any(|s| s.contains("http-public")));
	let config = Config::parse([], |key| {
		(key == "GLOWCAP_ROOMS_HTTP_PUBLIC").then(|| "https://rooms.example/app/".into())
	})
	.unwrap()
	.unwrap();
	assert_eq!(
		config.public.as_ref().map(url::Url::as_str),
		Some("https://rooms.example/app/")
	);
	assert!(parse(&[]).public.is_none());
	// A bare origin is the address with the path `/`, as the URL standard
	// reads it, and a path without its final `/` is refused whole.
	let config = Config::parse(["--http-public=https://rooms.example".into()], |_| None)
		.unwrap()
		.unwrap();
	assert_eq!(
		config.public.as_ref().map(url::Url::as_str),
		Some("https://rooms.example/")
	);
	for refused in [
		"https://rooms.example/app",
		"ws://rooms.example/",
		"https://rooms.example/?x",
		"rooms.example/",
	] {
		let error = Config::parse([format!("--http-public={refused}")], |_| None)
			.err()
			.expect("refused");
		assert!(error.contains("--http-public") && error.contains(refused), "{error}");
	}
	assert_eq!(
		Config::parse(["--http-public".into()], |_| None)
			.err()
			.expect("refused"),
		"--http-public needs a value, as in --http-public=<url>"
	);
}
#[test]
fn trusted_proxies_are_read_from_arguments_or_environment_and_stay_out_of_server_args() {
	let config = Config::parse(["--http-trusted-proxies=10.0.0.0/8, fd00::1".into()], |_| None)
		.unwrap()
		.unwrap();
	assert_eq!(config.admission.trusted_proxies.len(), 2);
	assert!(!config.server_args.iter().any(|s| s.contains("trusted-proxies")));
	let config = Config::parse([], |key| {
		(key == "GLOWCAP_ROOMS_HTTP_TRUSTED_PROXIES").then(|| "127.0.0.1".into())
	})
	.unwrap()
	.unwrap();
	assert_eq!(config.admission.trusted_proxies.len(), 1);
	assert_eq!(parse(&[]).admission.trusted_proxies.len(), 0);
	let error = Config::parse(["--http-trusted-proxies=10.0.0.0/40".into()], |_| None)
		.err()
		.unwrap();
	assert!(error.contains("10.0.0.0/40"), "{error}");
}

#[test]
fn browser_asset_mode_is_explicit() {
	assert!(matches!(parse(&[]).browser_assets, BrowserAssets::Source(path) if path == Path::new("apps/rooms/web")));
	assert!(
		matches!(parse(&["--assets=prepared", "--prepared"]).browser_assets, BrowserAssets::Prepared(path) if path == Path::new("prepared"))
	);
	assert!(matches!(
		parse(&["--no-browser-assets"]).browser_assets,
		BrowserAssets::Disabled
	));
}

#[test]
fn disabled_assets_cannot_hide_an_asset_configuration() {
	for args in [
		["--no-browser-assets", "--assets=prepared"].as_slice(),
		["--no-browser-assets", "--prepared"].as_slice(),
	] {
		assert!(Config::parse(args.iter().map(|arg| (*arg).to_owned()), |_| None).is_err());
	}
}
