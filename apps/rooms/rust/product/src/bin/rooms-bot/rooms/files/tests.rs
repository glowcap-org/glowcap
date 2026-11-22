use super::*;
use rooms_application::content::session::custody::MAX_EFFECTS;
use rooms_testing::scratch::Scratch;

fn push(directory: &Path, row: &str) {
	let mut file = std::fs::OpenOptions::new()
		.create(true)
		.append(true)
		.open(directory.join("inbox.jsonl"))
		.unwrap();
	writeln!(file, "{row}").unwrap();
}

fn calls(directory: &Path) -> Vec<serde_json::Value> {
	std::fs::read_to_string(directory.join("calls.jsonl"))
		.unwrap_or_default()
		.lines()
		.map(|line| serde_json::from_str(line).unwrap())
		.collect()
}

#[tokio::test]
async fn events_after_a_cursor_arrive_with_their_typed_meaning() {
	let dir = Scratch::create("bot-files");
	push(&dir, r#"{"at":1,"conversation":"c","kind":"direct","text":"hi"}"#);
	push(
		&dir,
		r#"{"at":2,"conversation":"r","kind":"room","sender":"ann","text":"x","mentions":{"member":true}}"#,
	);
	push(&dir, r#"{"at":3,"conversation":"r","kind":"room","notice":true}"#);
	let rooms = Files::open(&dir);
	let all = rooms.events(&Cursor::start(), false).await.unwrap();
	assert!(matches!(&all.events[0].body, Body::Line(line) if line.sender == Sender::Peer(None)));
	let batch = rooms.events(&all.events[0].cursor, false).await.unwrap();
	assert_eq!(batch.cursor, cursor(3));
	assert_eq!(batch.events.len(), 2);
	assert!(matches!(&batch.events[0].body, Body::Line(line) if line.mentions.member && line.id == "l2"));
	assert_eq!(batch.events[1].body, Body::Other);
	let head = rooms.events(&batch.cursor, false).await.unwrap();
	assert!(head.events.is_empty() && head.cursor == batch.cursor);
}

#[tokio::test]
async fn cursors_do_not_sort_like_their_positions_and_reads_are_bounded() {
	let dir = Scratch::create("bot-files-order");
	for at in 1..=(BATCH as u64 + 20) {
		push(
			&dir,
			&format!(r#"{{"at":{at},"conversation":"c","kind":"room","sender":"ann","text":"x"}}"#),
		);
	}
	assert!(cursor(9).as_str() > cursor(16).as_str());
	let rooms = Files::open(&dir);
	let first = rooms.events(&Cursor::start(), false).await.unwrap();
	assert_eq!(first.events.len(), BATCH);
	let rest = rooms.events(&first.cursor, false).await.unwrap();
	assert_eq!(rest.events.len(), 20);
}

#[tokio::test]
async fn gap_and_unavailable_rows_set_their_flags_and_move_the_cursor() {
	let dir = Scratch::create("bot-files-gap");
	push(&dir, r#"{"at":9,"gap":true}"#);
	push(&dir, r#"{"at":10,"unavailable":true}"#);
	let batch = Files::open(&dir).events(&Cursor::start(), false).await.unwrap();
	assert!(batch.gap && batch.unavailable && batch.events.is_empty());
	assert_eq!(batch.cursor, cursor(10));
}

#[tokio::test]
async fn an_events_fault_fails_every_read_while_it_stands() {
	let dir = Scratch::create("bot-files-access");
	let rooms = Files::open(&dir);
	for (name, kind) in [
		("paused", RoomsErrorKind::Paused),
		("revoked", RoomsErrorKind::Revoked),
		("refused", RoomsErrorKind::Refused),
		("unreachable", RoomsErrorKind::Unreachable),
	] {
		std::fs::write(dir.join("events-fault"), name).unwrap();
		assert_eq!(rooms.events(&Cursor::start(), false).await.unwrap_err().kind, kind);
	}
	std::fs::remove_file(dir.join("events-fault")).unwrap();
	assert!(rooms.events(&Cursor::start(), false).await.is_ok());
}

#[tokio::test]
async fn sending_an_operation_twice_at_its_base_posts_one_line_and_another_base_is_refused() {
	let dir = Scratch::create("bot-files-send");
	let rooms = Files::open(&dir);
	let conversation = ConversationId::new("c");
	let line = Outgoing {
		conversation: &conversation,
		text: "hello",
		operation: "op1",
	};
	let base = rooms.base().await.unwrap();
	assert_eq!(rooms.send(&line, base).await.unwrap(), Outcome::Committed);
	assert_eq!(rooms.send(&line, base).await.unwrap(), Outcome::Committed);
	assert_eq!(rooms.sent().unwrap().len(), 1);
	assert_eq!(calls(&dir).len(), 2);
	let later = rooms.base().await.unwrap();
	assert_eq!(
		rooms.send(&line, later).await.unwrap_err().kind,
		RoomsErrorKind::Refused
	);
	let other = Outgoing {
		text: "different",
		..line
	};
	assert_eq!(
		rooms.send(&other, base).await.unwrap_err().kind,
		RoomsErrorKind::Refused
	);
	assert_eq!(rooms.sent().unwrap().len(), 1);
}

#[tokio::test]
async fn injected_send_outcomes_commit_exactly_what_they_name() {
	let dir = Scratch::create("bot-files-faults");
	let rooms = Files::open(&dir);
	let conversation = ConversationId::new("c");
	let line = |operation| Outgoing {
		conversation: &conversation,
		text: "t",
		operation,
	};
	std::fs::write(
		dir.join("send-faults"),
		"refused\npending\nok\nuncertain\nok\nlost\nok\nconflict\nok\nunknown\nvanished\n",
	)
	.unwrap();
	let base = Base(0);
	assert_eq!(
		rooms.send(&line("a"), base).await.unwrap_err().kind,
		RoomsErrorKind::Refused
	);
	assert_eq!(rooms.sent().unwrap().len(), 0);
	assert_eq!(rooms.send(&line("b"), base).await.unwrap(), Outcome::Pending);
	assert_eq!(rooms.observe(&line("b"), base).await.unwrap(), Outcome::Committed);
	let uncertain = rooms.send(&line("c"), base).await.unwrap_err();
	assert_eq!(uncertain.kind, RoomsErrorKind::Uncertain);
	assert_eq!(rooms.observe(&line("c"), base).await.unwrap(), Outcome::Committed);
	let lost = rooms.send(&line("d"), base).await.unwrap_err();
	assert_eq!(lost.kind, RoomsErrorKind::Uncertain);
	assert_eq!(rooms.observe(&line("d"), base).await.unwrap(), Outcome::Absent);
	assert_eq!(
		rooms.echoed(&line("d"), &Cursor::start()).await.unwrap(),
		Echo::NotFound
	);
	assert_eq!(rooms.send(&line("e"), base).await.unwrap(), Outcome::Conflict);
	assert_eq!(
		rooms.send(&line("e"), base).await.unwrap(),
		Outcome::Conflict,
		"a fenced-out operation was admitted at its base"
	);
	let base = rooms.base().await.unwrap();
	assert_eq!(rooms.send(&line("f"), base).await.unwrap(), Outcome::Unknown);
	assert_eq!(rooms.echoed(&line("f"), &Cursor::start()).await.unwrap(), Echo::Found);
	assert_eq!(rooms.send(&line("g"), base).await.unwrap(), Outcome::Unknown);
	assert_eq!(
		rooms.echoed(&line("g"), &Cursor::start()).await.unwrap(),
		Echo::NotFound
	);
	let sent: Vec<String> = rooms.sent().unwrap().into_iter().map(|row| row.operation).collect();
	assert_eq!(sent, ["b", "c", "f"]);
	std::fs::write(dir.join("echo-fault"), "").unwrap();
	assert_eq!(
		rooms.echoed(&line("b"), &Cursor::start()).await.unwrap(),
		Echo::Unknowable
	);
	std::fs::write(dir.join("echo-fault"), "restarted").unwrap();
	assert_eq!(
		rooms.echoed(&line("b"), &Cursor::start()).await.unwrap(),
		Echo::Restarted
	);
}

#[tokio::test]
async fn keeping_moves_the_fence_and_released_receipts_free_their_place() {
	let dir = Scratch::create("bot-files-release");
	let rooms = Files::open(&dir);
	let conversation = ConversationId::new("c");
	let line = |operation: &'static str| Outgoing {
		conversation: &conversation,
		text: "t",
		operation,
	};
	let base = rooms.base().await.unwrap();
	assert_eq!(rooms.send(&line("a"), base).await.unwrap(), Outcome::Committed);
	let stale = rooms.base().await.unwrap();
	rooms.keep(&line("a"), base).await.unwrap();
	assert_eq!(
		rooms.send(&line("b"), stale).await.unwrap(),
		Outcome::Conflict,
		"a send based before a kept line was admitted"
	);
	assert_eq!(rooms.observe(&line("b"), stale).await.unwrap(), Outcome::Absent);
	std::fs::write(dir.join("send-faults"), "vanished\n").unwrap();
	let base = rooms.base().await.unwrap();
	assert_eq!(rooms.send(&line("c"), base).await.unwrap(), Outcome::Unknown);
	for n in 0..MAX_EFFECTS * 2 {
		let operation = format!("r{n}");
		let sent = Outgoing {
			conversation: &conversation,
			text: "t",
			operation: &operation,
		};
		let base = rooms.base().await.unwrap();
		assert_eq!(rooms.send(&sent, base).await.unwrap(), Outcome::Committed);
		rooms.release(&sent, base).await.unwrap();
	}
	assert_eq!(
		rooms.observe(&line("c"), base).await.unwrap(),
		Outcome::Unknown,
		"an unsettled receipt was let go"
	);
	rooms.release(&line("c"), base).await.unwrap();
	assert_eq!(rooms.observe(&line("c"), base).await.unwrap(), Outcome::Absent);
}

#[tokio::test]
async fn receipts_nobody_keeps_fill_the_session_until_it_refuses_and_kept_ones_never_do() {
	let dir = Scratch::create("bot-files-receipts");
	let rooms = Files::open(&dir);
	let conversation = ConversationId::new("c");
	let operations: Vec<String> = (0..20).map(|n| format!("op{n}")).collect();
	fn line<'a>(conversation: &'a ConversationId, operation: &'a str) -> Outgoing<'a> {
		Outgoing {
			conversation,
			text: "t",
			operation,
		}
	}
	for operation in &operations {
		let base = rooms.base().await.unwrap();
		assert_eq!(
			rooms.send(&line(&conversation, operation), base).await.unwrap(),
			Outcome::Committed
		);
		rooms.keep(&line(&conversation, operation), base).await.unwrap();
	}
	let kept = rooms.sent().unwrap().len();
	assert_eq!(kept, operations.len(), "kept lines never fill the receipts");
	let mut refused = None;
	for n in 0..=MAX_EFFECTS {
		let operation = format!("unkept{n}");
		let base = rooms.base().await.unwrap();
		if let Err(error) = rooms.send(&line(&conversation, &operation), base).await {
			refused = Some((n, error.kind));
			break;
		}
	}
	assert_eq!(refused, Some((MAX_EFFECTS, RoomsErrorKind::Refused)));
	assert_eq!(
		rooms.observe(&line(&conversation, "op0"), Base(0)).await.unwrap(),
		Outcome::Absent,
		"the oldest kept receipt was let go"
	);
}

#[tokio::test]
async fn an_unknown_receipt_is_let_go_like_a_settled_one_though_its_line_posted() {
	fn line<'a>(conversation: &'a ConversationId, operation: &'a str) -> Outgoing<'a> {
		Outgoing {
			conversation,
			text: "t",
			operation,
		}
	}
	let dir = Scratch::create("bot-files-unknown-evicted");
	let rooms = Files::open(&dir);
	let conversation = ConversationId::new("c");
	std::fs::write(dir.join("send-faults"), "unknown\n").unwrap();
	let base = rooms.base().await.unwrap();
	let posted = line(&conversation, "posted");
	assert_eq!(rooms.send(&posted, base).await.unwrap(), Outcome::Unknown);
	for n in 0..MAX_EFFECTS {
		let operation = format!("later{n}");
		let later = line(&conversation, &operation);
		let base = rooms.base().await.unwrap();
		rooms.send(&later, base).await.unwrap();
		rooms.keep(&later, base).await.unwrap();
	}
	assert_eq!(rooms.observe(&posted, base).await.unwrap(), Outcome::Absent);
	assert_eq!(
		rooms.echoed(&posted, &Cursor::start()).await.unwrap(),
		Echo::Found,
		"the line of the receipt let go was not posted"
	);
}
