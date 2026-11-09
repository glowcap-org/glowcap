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
		let printed = print_capabilities(&state, web.port).await.expect("the read succeeds");
		let recipe = |token: &str| {
			printed
				.lines()
				.find_map(|line| line.strip_prefix(token).and_then(|rest| rest.strip_prefix(' ')))
				.unwrap_or_else(|| panic!("{token} in {printed}"))
				.to_owned()
		};
		// A sturdyref is the peer's locator with `/s/<swiss>` before its hints.
		let peer = locator.split('?').next().unwrap();
		let operator = recipe("ROOMS-OPERATOR");
		assert!(
			operator.starts_with(&format!("{peer}/s/")),
			"{operator} is not under {locator}"
		);
		assert!(recipe("ROOMS-TRACE").contains("/s/"), "{printed}");
		assert_eq!(
			printed.lines().filter(|line| line.contains("not minted here")).count(),
			4,
			"{printed}"
		);
		web.stop().await;
		// Started again without the trace, the kept swiss prints with the
		// option that serves it, because the front said the timeline is off.
		let mut options = Web::options(0);
		options.insert("state", state.display().to_string());
		options.insert("capabilities", "operator".to_owned());
		let mut web = Web::spawn(Web::command_with(options));
		web.ready().await;
		let printed = print_capabilities(&state, web.port).await.expect("the read succeeds");
		let trace = printed.lines().find(|line| line.starts_with("ROOMS-TRACE")).unwrap();
		assert!(
			trace.contains("not running") && trace.contains("--capabilities=trace"),
			"{trace}"
		);
		assert!(!trace.contains("/s/"), "{trace}");
		web.stop().await;
		// With the front gone the read names the next step, instead of a bare
		// connection error.
		let refused = print_capabilities(&state, web.port).await.expect_err("nothing answers");
		assert!(refused.contains("127.0.0.1:"), "{refused}");
		assert!(refused.contains("GLOWCAP_ROOMS_LOCATOR"), "{refused}");
	})
	.await
	.expect("capability read deadline");
}

/// `rooms-web --print-capabilities=<state>` against the front on `port`, with
/// no locator variables set, as the deployment container runs it.
async fn print_capabilities(state: &Path, port: u16) -> Result<String, String> {
	let mut command = Command::new(Web::binary());
	command
		.arg(format!("--print-capabilities={}", state.display()))
		.env("GLOWCAP_ROOMS_HTTP_PORT", port.to_string())
		.env_remove("GLOWCAP_ROOMS_LOCATOR")
		.env_remove("GLOWCAP_ROOMS_TRACE_LOCATOR")
		.current_dir(std::env::temp_dir())
		.kill_on_drop(true);
	if std::env::var_os("GLOWCAP_ROOMS_WEB_TEST_BIN").is_some() {
		command.env_remove("LD_LIBRARY_PATH").env_remove("DYLD_LIBRARY_PATH");
	}
	let output = command.output().await.unwrap();
	if output.status.success() {
		Ok(String::from_utf8(output.stdout).unwrap())
	} else {
		Err(String::from_utf8(output.stderr).unwrap())
	}
}
