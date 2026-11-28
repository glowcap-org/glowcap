//! A real Rooms session receives a timed post while no harness turn runs.
use super::{
	captp::{World, action},
	captp_direct::{output, turn},
	rig::eventually,
};
use serde_json::json;

#[test]
fn a_saved_reminder_posts_to_its_original_dm_after_bot_restart() {
	let world = World::new("bot-reminder-restart");
	let bot = world.serve();
	let request = action(
		"remind",
		json!({"id":["first"],"in":["10s"],"text":["check the build"]}),
		&[],
	);
	let actions = json!([request.clone(), request, action("reminders", json!({}), &[])]);
	world.dm(&format!("act:{actions}"));
	world.await_line("direct", "exit=0 exit=0 exit=0");
	let created = output(&world, 0);
	assert_eq!(created, output(&world, 1));
	assert_eq!(output(&world, 2)["reminders"].as_array().unwrap().len(), 1);
	assert_eq!(
		turn(
			&world,
			&[
				action("reminders", json!({}), &[]),
				action("cancel-reminder", json!({"id":["first"]}), &[])
			]
		),
		"exit=0 exit=1"
	);
	assert_eq!(output(&world, 0)["reminders"], json!([]));
	world.stopped(bot);
	let bot = world.serve();
	world.await_line("direct", "[Reminder] check the build");
	eventually("the posted reminder to settle", || {
		let status = world.rig.status();
		(status["reminders"]["delivered"] == 1).then_some(())
	});
	world.stopped(bot);
	assert_eq!(world.count("direct", "[Reminder] check the build"), 1);
	assert_eq!(world.count("room", "[Reminder] check the build"), 0);
	world.finish();
}

#[test]
fn a_scheduled_turn_returns_once_without_interactive_actions() {
	let world = World::new("bot-scheduled-task");
	let bot = world.serve();
	let actions = json!([
		action("workspace", json!({}), &[]),
		action(
			"say",
			json!({"dm": ["other"], "text": ["outside scheduled scope"]}),
			&[]
		),
		action(
			"schedule",
			json!({"id": ["nested"], "in": ["1s"], "task": ["keep going"]}),
			&[]
		),
	]);
	let task = format!("act:{actions}");
	let schedule = action("schedule", json!({"id": ["review"], "in": ["8s"], "task": [task]}), &[]);
	world.dm(&format!("act:{}", json!([schedule])));
	world.await_line("direct", "exit=0");
	world.stopped(bot);
	let bot = world.serve();
	world.await_line("direct", "[Check-in] exit=1 exit=1 exit=1");
	for i in 0..3 {
		let refused = output(&world, i);
		assert!(
			refused["error"]["message"]
				.as_str()
				.is_some_and(|message| message.contains("Interactive Rooms actions require a message turn")),
			"scheduled action {i}: {refused}"
		);
	}
	world.stopped(bot);
	assert_eq!(world.count("direct", "[Check-in] exit=1 exit=1 exit=1"), 1);
	assert_eq!(world.count("room", "outside scheduled scope"), 0);
	world.finish();
}

#[test]
fn replacing_the_grant_retires_the_original_room_reminder() {
	use super::session_rig::run_within;
	use std::time::Duration;
	let world = World::new("bot-reminder-grant");
	run_within(Duration::from_secs(60), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("first bot", &terms).await.unwrap();
		let second = grants.issue("second bot", &terms).await.unwrap();
		let bot = world.rig.serve_linked(&first.link, json!({}));
		let request = action(
			"remind",
			json!({"id":["review"],"in":["1h"],"text":["original grant only"]}),
			&[],
		);
		assert_eq!(turn(&world, &[request]), "exit=0");
		world.stopped(bot);
		let bot = world.rig.serve_replacing(&second.link);
		eventually("the original grant to lose its scheduled reminder", || {
			(world.rig.status()["reminders"]["access-lost"] == 1).then_some(())
		});
		assert_eq!(turn(&world, &[action("reminders", json!({}), &[])]), "exit=0");
		assert_eq!(output(&world, 0)["reminders"], json!([]));
		world.stopped(bot);
		assert_eq!(world.count("room", "[Reminder] original grant only"), 0);
		world
			.rig
			.assert_keeps_no_link([first.link.as_str(), second.link.as_str()]);
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

#[test]
fn a_crash_after_delivery_observes_the_original_receipt_without_reposting() {
	let world = World::new("bot-reminder-delivery-crash");
	let mut bot = world.serve_at(Some("after-send@2"));
	let request = action(
		"remind",
		json!({"id":["proof"],"in":["4s"],"text":["check the receipt"]}),
		&[],
	);
	assert_eq!(turn(&world, &[request]), "exit=0");
	assert!(!bot.process.wait().success());
	world.await_line("room", "[Reminder] check the receipt");
	let bot = world.serve();
	eventually("the committed timer receipt to be observed and released", || {
		let path = world.rig.dir.join("reminders/schedules.json");
		let book: serde_json::Value = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
		let settled = &book["rows"][0]["state"]["Finished"];
		(settled["outcome"] == "delivered" && settled["release"].is_null()).then_some(())
	});
	world.stopped(bot);
	assert_eq!(world.count("room", "[Reminder] check the receipt"), 1);
	world.finish();
}

#[test]
fn a_finite_series_resumes_each_due_slot_once_and_preserves_its_minute_cadence() {
	use serde_json::Value;
	use std::{fs, time::SystemTime};

	let world = World::new("bot-reminder-cadence");
	let table = world.rig.dir.join("reminders/schedules.json");
	let read = || serde_json::from_slice::<Value>(&fs::read(&table).unwrap()).unwrap();
	// With the bot stopped, advance only the saved due time to exercise the
	// same recovery path as a host coming online when the next slot is due.
	let make_due = |book: &mut Value| {
		let now = SystemTime::now()
			.duration_since(SystemTime::UNIX_EPOCH)
			.unwrap()
			.as_secs();
		book["rows"][0]["due"] = json!(now);
		fs::write(&table, serde_json::to_vec(book).unwrap()).unwrap();
		now
	};
	let request = action(
		"remind",
		json!({"id":["check"],"in":["1h"],"every":["1m"],"count":["2"],"text":["check in"]}),
		&[],
	);
	let bot = world.serve();
	assert_eq!(turn(&world, &[request]), "exit=0");
	world.stopped(bot);
	let mut first = read();
	let first_due = make_due(&mut first);
	let bot = world.serve();
	world.await_line("room", "[Reminder] check in");
	eventually("the next slot after the first receipt settles", || {
		(read()["rows"][0]["occurrence"] == 2).then_some(())
	});
	world.stopped(bot);
	let mut second = read();
	let row = &second["rows"][0];
	assert_eq!(row["state"], "Scheduled");
	assert_eq!(row["due"], first_due + 60);
	assert_eq!(row["delivered"], 1);
	assert_ne!(row["operation"], first["rows"][0]["operation"]);
	assert_eq!(world.count("room", "[Reminder] check in"), 1);

	make_due(&mut second);
	let bot = world.serve();
	eventually("the final receipt to settle", || {
		let row = &read()["rows"][0];
		let finished = &row["state"]["Finished"];
		(row["delivered"] == 2 && finished["outcome"] == "delivered" && finished["release"].is_null()).then_some(())
	});
	world.stopped(bot);
	eventually("both reminder lines to reach the room", || {
		(world.count("room", "[Reminder] check in") == 2).then_some(())
	});
	world.finish();
}

#[test]
fn reopening_the_same_dm_id_does_not_receive_the_previous_routes_reminder() {
	use super::{captp::FRIEND, captp_direct::say};
	let world = World::new("bot-reminder-replaced-dm");
	let bot = world.serve();
	assert_eq!(turn(&world, &[say(FRIEND, "first route")]), "exit=0");
	let conversation = output(&world, 0)["conversation"].as_str().unwrap().to_owned();
	world.await_line("direct", "first route");
	let request = action(
		"remind",
		json!({"id":["first"],"in":["8s"],"text":["original route only"]}),
		&[],
	);
	world.dm_again(&format!("act:{}", json!([request])));
	world.await_line("direct", "exit=0");
	assert_eq!(
		turn(
			&world,
			&[
				action("command", json!({}), &["closeDirect", &conversation]),
				say(FRIEND, "replacement route"),
			]
		),
		"exit=0 exit=0"
	);
	assert_eq!(output(&world, 1)["conversation"], conversation);
	world.await_line("direct", "replacement route");
	eventually("the changed DM route to retire the timer", || {
		(world.rig.status()["reminders"]["target-changed"] == 1).then_some(())
	});
	world.stopped(bot);
	assert_eq!(world.count("direct", "[Reminder] original route only"), 0);
	world.finish();
}

#[test]
fn a_crash_after_scheduled_model_start_cannot_charge_a_second_run() {
	use super::rig::runs;
	let world = World::new("bot-timer-model-interrupted");
	let mut bot = world.serve();
	let schedule = action(
		"schedule",
		json!({"id": ["once"], "in": ["2s"], "task": ["wait-file:unexpected replay"]}),
		&[],
	);
	assert_eq!(turn(&world, &[schedule]), "exit=0");
	let work = eventually("the scheduled model to start", || {
		std::fs::read_dir(world.rig.dir.join("work"))
			.ok()?
			.flatten()
			.map(|entry| entry.path())
			.find(|p| p.join("waiting.marker").is_file())
	});
	let starts = runs(&work);
	assert!(starts >= 1);
	bot.kill();
	assert!(!bot.process.wait().success());
	let bot = world.serve();
	std::fs::write(work.join("release"), "").unwrap();
	eventually("the interrupted task to report its outcome", || {
		world
			.seen()
			.iter()
			.any(|line| line.kind == "room" && line.text.contains("interrupted"))
			.then_some(())
	});
	world.stopped(bot);
	assert_eq!(runs(&work), starts, "the scheduled model started a second time");
	assert_eq!(world.count("room", "unexpected replay"), 0);
	world.finish();
}

#[test]
fn scheduled_room_and_direct_prompts_receive_their_own_recent_addressed_messages() {
	let world = World::new("check-in-recent-context");
	let bot = world.serve();
	world.dm("reply:private thread detail");
	world.await_line("direct", "private thread detail");
	world.room("@bot-host reply:room thread detail");
	world.await_line("room", "room thread detail");
	let schedule = |id: &str, task: &str| action("schedule", json!({"id":[id],"in":["2s"],"task":[task]}), &[]);
	world.dm_again(&format!(
		"act:{}",
		json!([schedule("in-dm", "reply:private check complete")])
	));
	world.await_line("direct", "exit=0");
	assert_eq!(
		turn(&world, &[schedule("in-room", "reply:room check complete")]),
		"exit=0"
	);
	world.await_line("direct", "[Check-in] private check complete");
	world.await_line("room", "[Check-in] room check complete");
	for (answer, expected, excluded) in [
		("private check complete", "private thread detail", "room thread detail"),
		("room check complete", "room thread detail", "private thread detail"),
	] {
		let prompt = std::fs::read_dir(world.rig.dir.join("work"))
			.unwrap()
			.flatten()
			.filter_map(|entry| std::fs::read_to_string(entry.path().join("prompt.txt")).ok())
			.find(|s| s.starts_with("Scheduled check-in") && s.contains(answer))
			.unwrap();
		assert!(prompt.contains(expected) && !prompt.contains(excluded), "{prompt}");
	}
	world.stopped(bot);
	world.finish();
}

#[test]
fn quota_deferral_survives_restart_without_rewriting_the_clock_or_blocking_text_reminders() {
	use std::{os::unix::fs::MetadataExt, time::Duration};
	let world = World::new("bot-deferred-hour");
	let bot = world
		.rig
		.serve_linked(&world.fixture.peers[0].link, json!({"conversation-limit":["1"]}));
	let task = action(
		"schedule",
		json!({"id":["review"], "in":["2s"], "task":["reply:limited review"]}),
		&[],
	);
	let text = action(
		"remind",
		json!({"id":["note"], "in":["5s"], "text":["a text reminder still arrives"]}),
		&[],
	);
	assert_eq!(turn(&world, &[task, text]), "exit=0 exit=0");
	eventually("the hourly deferral to reach the clock", || {
		(world.rig.status()["reminders"]["waiting-for-hourly-limit"] == 1).then_some(())
	});
	world.await_line("room", "[Reminder] a text reminder still arrives");
	let table = world.rig.dir.join("reminders/schedules.json");
	eventually("the text reminder receipt to settle", || {
		let book: serde_json::Value = serde_json::from_slice(&std::fs::read(&table).ok()?).ok()?;
		book["rows"]
			.as_array()?
			.iter()
			.any(|r| {
				r["id"] == "note"
					&& r["state"]["Finished"]["outcome"] == "delivered"
					&& r["state"]["Finished"]["release"].is_null()
			})
			.then_some(())
	});
	world.stopped(bot);
	let signature = || {
		let m = table.metadata().unwrap();
		(m.ino(), m.ctime(), m.ctime_nsec())
	};
	let deferred = signature();
	let bot = world.serve();
	std::thread::sleep(Duration::from_secs(3));
	assert_eq!(world.rig.status()["reminders"]["waiting-for-hourly-limit"], 1);
	assert_eq!(signature(), deferred, "idle ticks rewrote a quota-deferred occurrence");
	assert_eq!(world.count("room", "[Check-in] limited review"), 0);
	world.stopped(bot);
	let bot = world
		.rig
		.serve_linked(&world.fixture.peers[0].link, json!({"conversation-limit":["2"]}));
	world.await_line("room", "[Check-in] limited review");
	world.stopped(bot);
	assert_eq!(world.count("room", "[Check-in] limited review"), 1);
	world.finish();
}
