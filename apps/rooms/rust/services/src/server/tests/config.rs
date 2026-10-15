//! How the server reads its options: arguments over environment, the state
//! directory, transports and their refusals, and history and where it is kept.
use super::*;

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
