//! A link the session refuses, against a real session, is stored nowhere.
use super::captp::World;
use super::session_rig::{assert_same_secret, run_within};
use serde_json::json;
use std::time::Duration;

/// A link the session refuses is stored nowhere: a first link leaves no
/// settings or link behind, and a replacement leaves the stored link serving.
#[test]
fn a_link_the_session_refuses_is_never_stored_and_the_stored_link_keeps_serving() {
	let world = World::new("bot-live-link-refused");
	run_within(Duration::from_secs(60), async {
		let (issuer, grants, terms) = world.issuer().await;
		let revoked = grants.issue("the refused first", &terms).await.unwrap();
		grants.revoke(&revoked.name).await.unwrap();
		let mut first = world.rig.serve_refused(&revoked.link, false);
		assert!(!first.wait().success(), "a revoked first link left the bot serving");
		for file in ["session.link", "config.json"] {
			assert!(!world.rig.dir.join(file).exists(), "a refused first link stored {file}");
		}

		let accepted = grants.issue("the bot", &terms).await.unwrap();
		let bot = world.rig.serve_linked(&accepted.link, json!({}));
		assert!(bot.stop().success(), "the bot exited with a failure");
		let stored = std::fs::read(world.rig.dir.join("session.link")).unwrap();
		// A note the stored link left. The replacement's last look runs under
		// the stored link, the old access, and the session refuses this open
		// (base 3 in directory `d` names nothing it holds), which a last look
		// decides nothing about. A refusal that stored nothing changes nothing.
		let opens = world.rig.dir.join("opens");
		std::fs::create_dir_all(&opens).unwrap();
		let note = opens.join(format!("{:032x}.json", 7));
		let body = json!({
			"base": 3,
			"introduction": {"directory": "d", "peer": "ann", "registration": "r"},
			"conversation": "c",
			"turn": 9999,
		});
		std::fs::write(&note, body.to_string()).unwrap();
		let on_disk = || {
			let mut files = Vec::new();
			for directory in [world.rig.dir.clone(), opens.clone()] {
				for entry in std::fs::read_dir(directory).unwrap().flatten() {
					let path = entry.path();
					if path.is_file() && entry.file_name() != "bot.log" && entry.file_name() != "status.json" {
						files.push((path.clone(), std::fs::read(&path).unwrap()));
					}
				}
			}
			files.sort();
			files
		};
		let before = on_disk();
		let mut replaced = world.rig.serve_refused(&revoked.link, true);
		assert!(!replaced.wait().success(), "a revoked replacement left the bot serving");
		// The stored link is among the files, so a failure names paths only.
		let after = on_disk();
		let paths =
			|files: &[(std::path::PathBuf, Vec<u8>)]| files.iter().map(|(path, _)| path.clone()).collect::<Vec<_>>();
		assert!(
			after == before,
			"a refused replacement changed what is stored: {:?} became {:?}",
			paths(&before),
			paths(&after)
		);
		std::fs::remove_file(&note).unwrap();
		// The refusal reaches the operator and the log, and nothing the bot
		// printed or wrote holds either link, which are the bot's authority.
		world
			.rig
			.assert_keeps_no_link([revoked.link.as_str(), accepted.link.as_str()]);
		assert_same_secret(
			std::fs::read(world.rig.dir.join("session.link")).unwrap(),
			stored,
			"a link the session refused was stored",
		);
		let bot = world.rig.serve_linked(&accepted.link, json!({}));
		world.dm("reply:still served");
		world.await_line("direct", "still served");
		assert!(bot.stop().success(), "the bot exited with a failure");
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}
