//! How the server reads its options: arguments over environment, the state
//! directory, transports and their refusals, and history and where it is kept.
use super::*;
use rooms_application::server::operations::BOOT_CAPABILITIES;

#[test]
fn rooms_server_configuration_resolves_options_and_environment() {
	let parse = |args: &[&str]| Config::parse(args.iter().map(|s| s.to_string()), |_| None);
	// Without a state directory the server is process-local.
	assert!(parse(&[]).unwrap().unwrap().state.is_none());
	assert!(parse(&["--help"]).unwrap().is_none());
	assert!(matches!(
		parse(&["--state=place"]).unwrap().unwrap().transport,
		Transport::Iroh(iroh::Reachability::Discovery)
	));
	for args in [
		vec!["--state=place", "--transport=no"],
		vec!["--state=place", "--state=again"],
		vec!["--state=place", "--wrong=x"],
		vec!["--state=place", "--transport=tcp", "--bind=0.0.0.0"],
		vec!["--state=place", "--transport=tcp", "--port=65536"],
	] {
		assert!(parse(&args).is_err(), "{args:?}");
	}
	let config = Config::parse(["--port=7".into()], |key| match key {
		"GLOWCAP_ROOMS_STATE" => Some(" place ".into()),
		"GLOWCAP_ROOMS_TRANSPORT" => Some("tcp".into()),
		"GLOWCAP_ROOMS_PORT" => Some("8".into()),
		_ => None,
	})
	.unwrap()
	.unwrap();
	assert_eq!(config.state, Some(PathBuf::from("place")));
	assert!(!config.history);
	let kept = Config::parse(["--history".into(), "--state=kept".into()], |_| None)
		.unwrap()
		.unwrap();
	assert!(kept.history);
	assert_eq!(kept.history_directory(), Some(PathBuf::from("kept/history")));
	assert!(Config::parse(["--state".into()], |_| None).is_err());
	let ephemeral = Config::parse(["--history".into()], |_| None).unwrap().unwrap();
	assert!(ephemeral.history_directory().is_none(), "history in memory alone");
	assert!(matches!(config.transport, Transport::Tcp { port: 7, .. }));
}

#[test]
fn admission_arguments_override_environment_and_reject_bad_policy() {
	let config = Config::parse(["--admission-rates=message=20/80".into()], |key| match key {
		"GLOWCAP_ROOMS_ADMISSION_RATES" => Some("message=1/1".into()),
		"GLOWCAP_ROOMS_ADMISSION_ROWS" => Some("123".into()),
		_ => None,
	})
	.unwrap()
	.unwrap();
	assert_eq!(
		config
			.admission
			.profile()
			.rate(rooms_application::admission::Class::Message)
			.burst(),
		20
	);
	assert_eq!(config.admission.rows(), 123);
	let summary = config.admission.summary();
	assert!(summary.contains("admission-rates=argument"));
	assert!(summary.contains("admission-rows=environment"));
	assert!(Config::parse(["--admission-rates=message=0/1".into()], |_| None).is_err());
}

#[test]
fn capabilities_name_what_to_mint_and_the_rest_stay_withheld() {
	let parse = |args: &[&str], env: fn(&str) -> Option<String>| {
		Config::parse(args.iter().map(|s| s.to_string()), env)
			.unwrap()
			.unwrap()
			.asked
	};
	let refused = |args: &[&str]| {
		Config::parse(args.iter().map(|s| s.to_string()), |_| None)
			.err()
			.map(|error| error.to_string())
			.expect("a refusal")
	};
	let held = |asked: Asked| {
		BOOT_CAPABILITIES
			.iter()
			.filter(|capability| asked.holds(capability.kind))
			.map(|capability| capability.name)
			.collect::<Vec<_>>()
	};
	assert_eq!(parse(&[], |_| None), Asked::default(), "nothing asked mints nothing");
	assert_eq!(
		held(parse(&["--capabilities=all"], |_| None)),
		BOOT_CAPABILITIES
			.iter()
			.map(|capability| capability.name)
			.collect::<Vec<_>>()
	);
	// A list mints only the names it holds, in the table's order.
	assert_eq!(
		held(parse(&["--capabilities=trace,peering"], |_| None)),
		["peering", "trace"]
	);
	let from_environment = parse(&[], |key| match key {
		"GLOWCAP_ROOMS_CAPABILITIES" => Some("admin-listeners,diagnostics,operator,peering,trace".into()),
		_ => None,
	});
	assert_eq!(
		held(from_environment),
		["admin-listeners", "diagnostics", "operator", "peering", "trace"]
	);
	// The option wins over the variable.
	let both = parse(&["--capabilities=irc"], |key| match key {
		"GLOWCAP_ROOMS_CAPABILITIES" => Some("all".into()),
		_ => None,
	});
	assert_eq!(held(both), ["irc"]);
	let names = format!(
		"all, or names from {}",
		BOOT_CAPABILITIES
			.iter()
			.map(|capability| capability.name)
			.collect::<Vec<_>>()
			.join(", ")
	);
	for (args, said) in [
		(["--capabilities=peering,nope"], "does not know \"nope\""),
		(["--capabilities=peering,,irc"], "has an empty item"),
		(["--capabilities=irc,irc"], "repeats \"irc\""),
		(["--capabilities=all,irc"], "takes all on its own, not in a list"),
		(["--capabilities="], "has an empty item"),
		(["--irc"], "unknown option: --irc"),
	] {
		let refusal = refused(&args);
		assert!(refusal.contains(said), "{refusal}");
		if args[0].starts_with("--capabilities") {
			assert!(refusal.contains(&names), "{refusal}");
		}
	}
	assert!(refused(&["--capabilities"]).contains("--capabilities takes a value"));
}

#[test]
fn every_boot_capability_is_mintable_alone_and_both_help_texts_list_the_table() {
	let names = BOOT_CAPABILITIES
		.iter()
		.map(|capability| capability.name)
		.collect::<Vec<_>>()
		.join(", ");
	for help in [super::super::HELP, crate::web::HELP] {
		assert!(help.contains(&names), "help lists {names}");
	}
	for capability in &BOOT_CAPABILITIES {
		let one = Asked::parse(capability.name).unwrap();
		assert!(one.holds(capability.kind), "{} is mintable on its own", capability.name);
		assert_eq!(
			BOOT_CAPABILITIES.iter().filter(|other| one.holds(other.kind)).count(),
			1,
			"{} mints itself alone",
			capability.name
		);
	}
	assert_ne!(Asked::parse("all").unwrap(), Asked::default());
}
