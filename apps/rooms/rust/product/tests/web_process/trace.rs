//! Discovery survives ephemeral ports and public routing that cannot be dialed
//! from inside a deployment. The shipped viewer receives replay and live data.
use super::*;

#[tokio::test(flavor = "current_thread")]
async fn native_trace_discovers_private_authority_and_follows_the_carried_feed() {
	tokio::time::timeout(Duration::from_secs(25), async {
        let state = startup::Fixture::new();
        let mut command = Web::endpoint_command(0);
        command.arg("--no-browser-assets")
            .env("GLOWCAP_RELAY_MAX_SESSIONS", "2")
            .arg(format!("--state={}", state.0.display()))
            .arg("--trace-connect=wss://trace.example.invalid/prefix/captp")
            .arg("--trace-publish=wss://trace.example.invalid/prefix/publish");
        let mut web = Web::spawn(command);
        web.ready().await;
        let viewer = || {
            let mut command = Command::new(Web::binary());
            command.arg("trace")
                .arg(format!("--state={}", state.0.display()))
                .arg(format!("--url=http://127.0.0.1:{}", web.port))
                .stdout(Stdio::piped()).stderr(Stdio::inherit()).kill_on_drop(true);
            if std::env::var_os("GLOWCAP_ROOMS_WEB_TEST_BIN").is_some() {
                command.env_remove("LD_LIBRARY_PATH").env_remove("DYLD_LIBRARY_PATH");
            }
            command
        };
        let output = viewer().arg("--print-link").output().await.unwrap();
        assert!(output.status.success());
        let link = String::from_utf8(output.stdout).unwrap();
        let parsed = glowcap::parse_sturdyref(link.trim(), glowcap::CaptpVersion::V1_0).unwrap();
        assert_eq!(parsed.locator.string_hint("captp-websocket").unwrap(), Some("wss://trace.example.invalid/prefix/captp"));
        let swiss = std::str::from_utf8(&parsed.swissnum).unwrap();
        assert_eq!(std::fs::read_to_string(state.0.join("trace")).unwrap().trim(), swiss);
        let carried = parsed.locator.clone().with_hint("captp-websocket", glowcap::HintValue::String(web.url("/trace/captp")));
        let denied = glowcap::format_sturdyref(&carried, "cd".repeat(32).as_bytes(), glowcap::CaptpVersion::V1_0).unwrap();
        let refused = viewer().arg(&denied).output().await.unwrap();
        assert!(!refused.status.success(), "the byte channel granted trace authority");
        assert!(refused.stdout.is_empty(), "a refused capability received trace records");
        let mut tail = viewer().arg("--json").spawn().unwrap();
        let mut lines = BufReader::new(tail.stdout.take().unwrap()).lines();
        let replay = tokio::time::timeout(Duration::from_secs(10), lines.next_line()).await.unwrap().unwrap().unwrap();
        assert_eq!(serde_json::from_str::<serde_json::Value>(&replay).unwrap()["kind"], "trace.replay-end");
        let (mut producer, _) = tokio_tungstenite::connect_async(web.url(&format!("/publish?cap={swiss}"))).await.unwrap();
        assert!(producer.next().await.unwrap().unwrap().to_text().unwrap().contains("trace.publish-ready"));
        producer.send(Message::Text(r#"{"v":1,"sim_t_ns":3,"kind":"ocapn.session-opened","session":"native-proof","a":"alpha","b":"beta","transport":"tcp"}"#.into())).await.unwrap();
        let line = tokio::time::timeout(Duration::from_secs(5), lines.next_line()).await.unwrap().unwrap().unwrap();
        let record: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(record["kind"], "ocapn.session-opened");
        assert!(record["session"].as_str().unwrap().ends_with("/native-proof"));
        nix::sys::signal::kill(nix::unistd::Pid::from_raw(tail.id().unwrap() as i32), nix::sys::signal::Signal::SIGTERM).unwrap();
        assert!(tokio::time::timeout(Duration::from_secs(5), tail.wait()).await.unwrap().unwrap().success());
        producer.close(None).await.unwrap();
        web.stop().await;
    }).await.expect("native trace process deadline");
}

#[tokio::test(flavor = "current_thread")]
async fn trace_discovery_distinguishes_a_disabled_feed_from_a_dead_service() {
	tokio::time::timeout(Duration::from_secs(10), async {
		let state = startup::Fixture::new();
		let mut command = Web::endpoint_command(0);
		command.args(["--no-browser-assets", "--trace=false"]);
		let mut web = Web::spawn(command);
		web.ready().await;
		let query = |print| {
			let mut command = Command::new(Web::binary());
			command.kill_on_drop(true);
			command
				.arg("trace")
				.arg(format!("--state={}", state.0.display()))
				.arg(format!("--url=http://127.0.0.1:{}", web.port));
			if print {
				command.arg("--print-link");
			}
			command
		};
		let disabled = query(true).output().await.unwrap();
		assert!(disabled.status.success() && disabled.stdout.is_empty());
		let refused = query(false).output().await.unwrap();
		assert!(!refused.status.success());
		assert!(String::from_utf8(refused.stderr).unwrap().contains("trace is disabled"));
		web.stop().await;
	})
	.await
	.expect("disabled trace discovery deadline");
}
