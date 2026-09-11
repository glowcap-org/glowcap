use super::*;
use rooms_application::session::checkpoint::invitations::RoomLink;

fn invitation(id: &str, token: &str) -> RoomLink {
	let link = glowcap::format_sturdyref(
		&glowcap::parse_locator("ocapn://offered.id").unwrap(),
		token.as_bytes(),
		glowcap::CaptpVersion::V1_0,
	)
	.unwrap();
	rooms_glowcap::routes::received_room_link(id, "alice", "offered room", "bob", &link).unwrap()
}
fn receipt(commands: &SessionCommands, id: &str, token: &str) -> Admission<u64> {
	commands.prepare_room_link(text(id), invitation(id, token)).unwrap()
}
fn revision(commands: &SessionCommands) -> u64 {
	commands.view().read(|s| s.revision()).unwrap().unwrap()
}

#[tokio::test]
async fn room_link_receipt_serializes_revision_selection_deduplicates_and_restores() {
	let temp = Temp::new();
	let (commands, worker) = SessionCommands::open(owner(&temp.0).await, crate::client::Deadline)
		.await
		.unwrap();
	let (events, trace) = events();
	let prior = commands
		.prepare_command(text("prior"), 0, Command::SetStanding, vec!["present".into()])
		.unwrap()
		.send()
		.unwrap();
	let first = receipt(&commands, "first", "one").send().unwrap();
	let duplicate = receipt(&commands, "duplicate", "one").send().unwrap();
	let second = receipt(&commands, "second", "two").send().unwrap();
	drop(receipt(&commands, "unsent", "absent"));
	let (run, ()) = tokio::join!(worker.run(events), async {
		assert_eq!(prior.wait().await.unwrap(), 1);
		assert_eq!(first.wait().await.unwrap(), 2);
		assert_eq!(duplicate.wait().await.unwrap(), 2);
		assert_eq!(second.wait().await.unwrap(), 3);
		assert_eq!(trace.borrow().revisions, [1, 2, 3]);
		let mut held = Vec::new();
		for index in 0..MAX_PENDING {
			held.push(receipt(&commands, &format!("queued-{index}"), "one"));
		}
		assert!(matches!(
			commands.prepare_room_link(text("overflow"), invitation("overflow", "one")),
			Err(AdmissionError::Full)
		));
		held.pop();
		assert_eq!(
			receipt(&commands, "recovered", "one")
				.send()
				.unwrap()
				.wait()
				.await
				.unwrap(),
			3
		);
		drop(held);
		let mut pending = Vec::new();
		for index in 2..16 {
			pending.push(
				receipt(&commands, &format!("room-{index}"), &format!("link-{index}"))
					.send()
					.unwrap(),
			);
		}
		for reply in pending {
			reply.wait().await.unwrap();
		}
		assert!(receipt(&commands, "seventeenth", "too-many")
			.send()
			.unwrap()
			.wait()
			.await
			.is_err());
		let full = revision(&commands);
		assert_eq!(full, 17);
		assert_eq!(
			receipt(&commands, "duplicate-at-capacity", "one")
				.send()
				.unwrap()
				.wait()
				.await
				.unwrap(),
			full
		);
		commands
			.prepare_command(text("dismiss"), full, Command::DismissInvitation, vec!["first".into()])
			.unwrap()
			.send()
			.unwrap()
			.wait()
			.await
			.unwrap();
		// Abandoning observation does not cancel a durable receipt already sent.
		drop(receipt(&commands, "replacement", "replacement").send().unwrap());
		commands.close().await.unwrap();
	});
	run.unwrap();
	drop(commands);
	let mut restored = owner(&temp.0).await;
	assert!(matches!(
		restored.load().await.unwrap(),
		crate::session_state::LoadStatus::Ready
	));
	let state: serde_json::Value = restored
		.view()
		.read(|s| serde_json::from_str(&s.checkpoint().unwrap().encode_for(Access::Admin).unwrap()).unwrap())
		.unwrap();
	let invitations = state["invitations"].as_array().unwrap();
	assert_eq!(invitations.len(), 16);
	assert!(invitations.iter().any(|i| i["id"] == "replacement"));
	assert!(invitations.iter().all(|i| i["id"] != "first" && i["id"] != "unsent"));
	assert!(invitations
		.iter()
		.all(|i| i["directory"] == "ocapn://offered.id" && i["nick"] == "alice" && i["from"] == "bob"));
	assert!(
		state["conversations"].as_array().unwrap().is_empty(),
		"receipt never accepts a room"
	);
}

#[tokio::test]
async fn room_link_queue_counts_record_capacity_without_widening_every_command() {
	let temp = Temp::new();
	let (commands, worker) = SessionCommands::open(owner(&temp.0).await, crate::client::Deadline)
		.await
		.unwrap();
	let link = "ocapn://offered.id/s/cm9vbQ";
	let label = "x".repeat(65536);
	let mut held = Vec::new();
	loop {
		let id = format!("large-{}", held.len());
		let invitation = rooms_glowcap::routes::received_room_link(&id, "alice", &label, "bob", link).unwrap();
		match commands.prepare_room_link(text(&id), invitation) {
			Ok(admission) => held.push(admission),
			Err(AdmissionError::Full) => break,
			Err(error) => panic!("unexpected admission error: {error}"),
		}
	}
	assert!(
		!held.is_empty() && held.len() < MAX_PENDING,
		"retained label bytes must fill the byte budget first"
	);
	held.pop();
	let replacement = rooms_glowcap::routes::received_room_link("replacement", "alice", &label, "bob", link).unwrap();
	assert!(commands.prepare_room_link(text("replacement"), replacement).is_ok());
	drop(held);
	let (events, _) = events();
	let (run, close) = tokio::join!(worker.run(events), commands.close());
	run.unwrap();
	close.unwrap();
}
