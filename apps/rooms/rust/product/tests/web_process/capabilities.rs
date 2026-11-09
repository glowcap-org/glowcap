//! The capability read beside a running front. `--print-capabilities` takes
//! the directory's locators from the front, so the operator supplies none.
use super::*;

#[tokio::test]
async fn print_capabilities_reads_the_running_fronts_locators() {
	tokio::time::timeout(Duration::from_secs(20), async {
		let state = rooms_testing::scratch::Scratch::create("web-capabilities");
		let mut options = Web::options(0);
		options.insert("state", state.display().to_string());
		options.insert("capabilities", "operator,trace".to_owned());
		let mut web = Web::spawn(Web::command_with(options));
		web.ready().await;
		let locator = web.status("locator").await;
		let printed = answered(print_capabilities(&state, Reach::Port(web.port)).await);
		let link = |token: &str| {
			printed
				.lines()
				.find_map(|line| line.strip_prefix(token).and_then(|rest| rest.strip_prefix(' ')))
				.unwrap_or_else(|| panic!("{token} in {printed}"))
				.to_owned()
		};
		// A sturdyref is the peer's locator with `/s/<swiss>` before its hints.
		let peer = locator.split('?').next().unwrap();
		let operator = link("ROOMS-OPERATOR");
		assert!(
			operator.starts_with(&format!("{peer}/s/")),
			"{operator} is not under {locator}"
		);
		assert!(link("ROOMS-TRACE").contains("/s/"), "{printed}");
		assert_eq!(
			printed.lines().filter(|line| line.contains("not minted here")).count(),
			4,
			"{printed}"
		);
		// The front `--url` names is the same front, so the same links print.
		assert_eq!(
			answered(print_capabilities(&state, Reach::Url(web.port)).await),
			printed
		);
		web.stop().await;
		// Started again without the trace, the kept swiss prints with the
		// option that serves it, because the front said the timeline is off.
		let mut options = Web::options(0);
		options.insert("state", state.display().to_string());
		options.insert("capabilities", "operator".to_owned());
		let mut web = Web::spawn(Web::command_with(options));
		web.ready().await;
		let printed = answered(print_capabilities(&state, Reach::Port(web.port)).await);
		let trace = printed.lines().find(|line| line.starts_with("ROOMS-TRACE")).unwrap();
		assert!(
			trace.contains("not running") && trace.contains("--capabilities=trace"),
			"{trace}"
		);
		assert!(!trace.contains("/s/"), "{trace}");
		web.stop().await;
		// With the front gone the read names the next step, instead of a bare
		// connection error.
		let refused = print_capabilities(&state, Reach::Port(web.port)).await;
		assert!(!refused.status.success(), "nothing answers");
		let refused = String::from_utf8(refused.stderr).unwrap();
		assert!(refused.contains("127.0.0.1:"), "{refused}");
		assert!(refused.contains("GLOWCAP_ROOMS_LOCATOR"), "{refused}");
	})
	.await
	.expect("capability read deadline");
}

#[tokio::test]
async fn print_capabilities_takes_an_environment_locator_and_refuses_invalid_state_whole() {
	let state = rooms_testing::scratch::Scratch::create("web-capabilities-offline");
	let swiss = "a".repeat(64);
	std::fs::write(state.join("diagnostics"), &swiss).unwrap();
	std::fs::write(state.join("trace"), "b".repeat(64)).unwrap();
	// With the locator supplied, no front is asked, so none needs to run.
	let printed = answered(print_capabilities(&state, Reach::Locator("ocapn://directory.id")).await);
	let link = printed
		.lines()
		.find_map(|line| line.strip_prefix("ROOMS-DIAGNOSTICS "))
		.unwrap_or_else(|| panic!("{printed}"));
	let parsed = glowcap::parse_sturdyref(link, glowcap::CaptpVersion::V1_0).unwrap();
	assert_eq!(parsed.locator, glowcap::parse_locator("ocapn://directory.id").unwrap());
	assert_eq!(String::from_utf8(parsed.swissnum).unwrap(), swiss);
	let trace = printed.lines().find(|line| line.starts_with("ROOMS-TRACE")).unwrap();
	assert!(trace.contains("GLOWCAP_ROOMS_TRACE_LOCATOR"), "{trace}");
	// One unreadable swiss refuses the whole read, with nothing printed and
	// nothing rewritten, so a partial handoff never reaches an operator.
	std::fs::write(state.join("diagnostics"), "invalid state").unwrap();
	let refused = print_capabilities(&state, Reach::Locator("ocapn://directory.id")).await;
	assert!(!refused.status.success());
	assert!(
		refused.stdout.is_empty(),
		"{}",
		String::from_utf8_lossy(&refused.stdout)
	);
	assert_eq!(
		std::fs::read_to_string(state.join("diagnostics")).unwrap(),
		"invalid state"
	);
}

/// How a read finds the directory's locators: the front on the local HTTP
/// port, as the deployment container runs it, the front `--url` names, or the
/// locator the environment supplies with no front at all.
enum Reach {
	Port(u16),
	Url(u16),
	Locator(&'static str),
}

/// `rooms-web --print-capabilities=<state>` with only what `reach` supplies.
async fn print_capabilities(state: &Path, reach: Reach) -> std::process::Output {
	let mut command = Command::new(Web::binary());
	command
		.arg(format!("--print-capabilities={}", state.display()))
		.env_remove("GLOWCAP_ROOMS_HTTP_PORT")
		.env_remove("GLOWCAP_ROOMS_LOCATOR")
		.env_remove("GLOWCAP_ROOMS_TRACE_LOCATOR")
		.current_dir(std::env::temp_dir())
		.kill_on_drop(true);
	match reach {
		Reach::Port(port) => {
			command.env("GLOWCAP_ROOMS_HTTP_PORT", port.to_string());
		}
		Reach::Url(port) => {
			command.arg(format!("--url=http://127.0.0.1:{port}"));
		}
		Reach::Locator(locator) => {
			command.env("GLOWCAP_ROOMS_LOCATOR", locator);
		}
	}
	if std::env::var_os("GLOWCAP_ROOMS_WEB_TEST_BIN").is_some() {
		command.env_remove("LD_LIBRARY_PATH").env_remove("DYLD_LIBRARY_PATH");
	}
	command.output().await.unwrap()
}

fn answered(output: std::process::Output) -> String {
	assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
	String::from_utf8(output.stdout).unwrap()
}
