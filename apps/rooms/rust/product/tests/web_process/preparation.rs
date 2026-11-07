//! Prepared generations are self-contained, immutable and selected atomically.
use super::*;

#[tokio::test(flavor = "current_thread")]
async fn web_prepares_and_serves_without_a_source_tree_or_compiler() {
	tokio::time::timeout(Duration::from_secs(25), async {
		let fixture = startup::Fixture::new();
		let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../web");
		let output = fixture.0.join("assets");
		let mut command = Command::new(Web::binary());
		command.arg(format!("--prepare={}", output.display()))
			.arg(format!("--assets={}", source.display())).kill_on_drop(true);
		let prepared = command.output().await.unwrap();
		assert!(prepared.status.success(), "{}", String::from_utf8_lossy(&prepared.stderr));
		let current = output.join("current");
		assert_eq!(String::from_utf8(prepared.stdout).unwrap().trim(), current.to_str().unwrap());
		let generation = std::fs::read_link(&current).unwrap();
		assert!(current.join("fonts/ibm-plex-sans-latin-wght-normal.woff2").is_file());
		assert!(!current.join("glowcap_host.wasm").exists());
		assert!(current.join("rooms_browser_bg.wasm").is_file());
		assert!(!current.join("main.tsx").exists());
		assert!(current.join("fonts/OFL.txt").is_file());
		for face in std::fs::read_dir(source.join("ui/fonts")).unwrap() {
			let face = face.unwrap();
			assert!(current.join("fonts").join(face.file_name()).is_file(), "every declared face ships");
		}
		fixture.script("deno", "import pathlib, os\npathlib.Path(os.environ['GLOWCAP_ROOMS_TEST_FIXTURE'], 'compiler-called').touch()\nraise SystemExit(99)\n");
		// The same graph reuses its validated immutable artifact without a build.
		fixture.env(&mut command);
		let reused = command.output().await.unwrap();
		assert!(reused.status.success(), "{}", String::from_utf8_lossy(&reused.stderr));
		assert_eq!(std::fs::read_link(&current).unwrap(), generation);
		// Source inspection fails before publication and preserves the pointer.
		let refused = Command::new(Web::binary()).arg(format!("--prepare={}", output.display()))
			.arg(format!("--assets={}", fixture.0.join("absent-source").display()))
			.kill_on_drop(true).output().await.unwrap();
		assert!(!refused.status.success());
		assert_eq!(std::fs::read_link(&current).unwrap(), generation);
		let mut command = Web::command(0);
		command.arg("--prepared").arg(format!("--assets={}", current.display()))
			.current_dir(&fixture.0);
		fixture.env(&mut command);
		let mut web = Web::spawn(command);
		web.ready().await;
		assert_eq!(web.status("check-ready").await, "rooms: ready");
		let application = std::fs::read(current.join("rooms_browser_bg.wasm")).unwrap();
		use sha2::{Digest, Sha256};
		let name = format!("rooms-{}.wasm", rooms_application::fields::lower_hex(&Sha256::digest(&application)));
		let module = web.request("HEAD", &format!("/{name}"), "").await;
		assert!(module.starts_with("HTTP/1.1 200"));
		assert!(module.to_lowercase().contains("content-type: application/wasm"));
		let entry = web.request("GET", "/page.js", "").await;
		assert!(entry.contains(&format!("\"{name}\"")), "the page must name its own immutable module, relative to its base");
		assert!(web.request("HEAD", "/fonts/ibm-plex-sans-latin-wght-normal.woff2", "").await.starts_with("HTTP/1.1 200"));
		assert!(!fixture.0.join("compiler-called").exists(), "prepared serving needs no compiler");
		web.stop().await;
		// The same generation, written as files for a static host at a base path.
		let exported = fixture.0.join("static");
		let export = || {
			Command::new(Web::binary()).arg(format!("--export-static={}", exported.display()))
				.arg(format!("--assets={}", current.display())).arg("--base=/rooms/app/")
				.kill_on_drop(true).output()
		};
		let written = export().await.unwrap();
		assert!(written.status.success(), "{}", String::from_utf8_lossy(&written.stderr));
		let index = std::fs::read_to_string(exported.join("index.html")).unwrap();
		assert!(index.contains(r#"<base href="/rooms/app/" />"#), "the page names its base");
		assert!(index.contains(r#"<meta http-equiv="Content-Security-Policy""#), "the page carries its policy");
		assert!(index.contains(r#"<meta name="rooms-host" content="static" />"#), "the page knows no server stands behind it");
		assert_eq!(std::fs::read_to_string(exported.join("404.html")).unwrap(), index, "a deep link opens the page");
		assert!(std::fs::read_to_string(exported.join("page.js")).unwrap().contains(&format!("\"{name}\"")));
		assert_eq!(std::fs::read(exported.join(&name)).unwrap(), application);
		assert!(exported.join("fonts/ibm-plex-sans-latin-wght-normal.woff2").is_file());
		assert!(!export().await.unwrap().status.success(), "an export never writes into an existing directory");
	}).await.expect("browser preparation and prepared serving deadline");
}
