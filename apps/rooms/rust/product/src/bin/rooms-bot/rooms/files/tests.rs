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
	let all = rooms.events(&Cursor::start(), Wait::Poll).await.unwrap();
	assert!(matches!(&all.events[0].body, Body::Line(line) if line.sender == Sender::Peer));
	let batch = rooms.events(&all.events[0].cursor, Wait::Poll).await.unwrap();
	assert_eq!(batch.cursor, cursor(3));
	assert_eq!(batch.events.len(), 2);
	assert!(matches!(&batch.events[0].body, Body::Line(line) if line.mentions.member && line.id == "l2"));
	assert_eq!(batch.events[1].body, Body::Other);
	let head = rooms.events(&batch.cursor, Wait::Poll).await.unwrap();
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
	let first = rooms.events(&Cursor::start(), Wait::Poll).await.unwrap();
	assert_eq!(first.events.len(), BATCH);
	let rest = rooms.events(&first.cursor, Wait::Poll).await.unwrap();
	assert_eq!(rest.events.len(), 20);
}

#[tokio::test]
async fn gap_and_unavailable_rows_set_their_flags_and_move_the_cursor() {
	let dir = Scratch::create("bot-files-gap");
	push(&dir, r#"{"at":9,"gap":true}"#);
	push(&dir, r#"{"at":10,"unavailable":true}"#);
	let batch = Files::open(&dir).events(&Cursor::start(), Wait::Poll).await.unwrap();
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
		("denied", RoomsErrorKind::Denied),
		("unreachable", RoomsErrorKind::Unreachable),
	] {
		std::fs::write(dir.join("events-fault"), name).unwrap();
		assert_eq!(rooms.events(&Cursor::start(), Wait::Poll).await.unwrap_err().kind, kind);
	}
	std::fs::remove_file(dir.join("events-fault")).unwrap();
	assert!(rooms.events(&Cursor::start(), Wait::Poll).await.is_ok());
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
	assert_eq!(
		rooms.observe(&other, base).await.unwrap(),
		Outcome::Absent,
		"a look at another line under the operation finds nothing applied"
	);
}

/// A send answered pending holds a running receipt: the list of held
/// receipts names it, as it names every unresolved receipt, and a release
/// keeps it until the next look finds it committed. A release with no
/// injected answer gives a receipt back.
#[tokio::test]
async fn a_running_receipt_is_kept_by_a_release_until_a_look_settles_it() {
	let dir = Scratch::create("bot-files-running");
	let rooms = Files::open(&dir);
	let conversation = ConversationId::new("c");
	let line = Outgoing {
		conversation: &conversation,
		text: "t",
		operation: "op1",
	};
	let base = rooms.base().await.unwrap();
	std::fs::write(dir.join("send-faults"), "pending\n").unwrap();
	assert_eq!(rooms.send(&line, base).await.unwrap(), Outcome::Pending);
	assert_eq!(
		rooms.held().await.unwrap(),
		["op1"],
		"a running receipt keeps its place"
	);
	assert_eq!(rooms.release(&line, base).await.unwrap(), Handback::Running);
	assert_eq!(rooms.observe(&line, base).await.unwrap(), Outcome::Committed);
	assert_eq!(rooms.held().await.unwrap(), ["op1"]);
	assert_eq!(rooms.release(&line, base).await.unwrap(), Handback::Taken);
	assert!(rooms.held().await.unwrap().is_empty());
	std::fs::write(dir.join("held-actions"), "op2\n").unwrap();
	assert_eq!(rooms.release_action("op2").await.unwrap(), Handback::Taken);
	assert!(
		rooms.held().await.unwrap().is_empty(),
		"the released action holds no place"
	);
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
	// A released receipt answers for its operation until it is pushed out,
	// and its line can no longer be kept.
	rooms.release(&line("c"), base).await.unwrap();
	assert_eq!(rooms.observe(&line("c"), base).await.unwrap(), Outcome::Unknown);
	assert_eq!(
		rooms.keep(&line("c"), base).await.unwrap_err().kind,
		RoomsErrorKind::Refused
	);
	for n in 0..MAX_EFFECTS {
		let operation = format!("u{n}");
		let sent = Outgoing {
			conversation: &conversation,
			text: "t",
			operation: &operation,
		};
		let base = rooms.base().await.unwrap();
		assert_eq!(rooms.send(&sent, base).await.unwrap(), Outcome::Committed);
	}
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
			refused = Some((n, error.kind, error.refused_before_dispatch));
			break;
		}
	}
	// The full session refuses before dispatch, a refusal the bot waits out.
	assert_eq!(refused, Some((MAX_EFFECTS, RoomsErrorKind::Unreachable, true)));
	assert_eq!(
		rooms.observe(&line(&conversation, "op0"), Base(0)).await.unwrap(),
		Outcome::Absent,
		"the oldest kept receipt was let go"
	);
}

/// An unknown receipt holds its place and is listed until its source
/// releases it, as a paused executor's does. A released one holds none, and
/// the session lets it go after the receipts with a known outcome, because
/// only an unknown one leaves its sender unable to tell whether its line
/// posted.
#[tokio::test]
async fn an_unknown_receipt_holds_its_place_until_released_and_then_goes_after_known_ones() {
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
	let known = line(&conversation, "known");
	let known_base = rooms.base().await.unwrap();
	rooms.send(&known, known_base).await.unwrap();
	rooms.keep(&known, known_base).await.unwrap();
	// Lines nobody kept hold their places, so each new one pushes out the
	// oldest receipt that may go.
	for n in 0..MAX_EFFECTS - 1 {
		let operation = format!("later{n}");
		let base = rooms.base().await.unwrap();
		rooms.send(&line(&conversation, &operation), base).await.unwrap();
	}
	assert_eq!(rooms.observe(&known, known_base).await.unwrap(), Outcome::Absent);
	assert_eq!(rooms.observe(&posted, base).await.unwrap(), Outcome::Unknown);
	assert!(rooms.held().await.unwrap().contains(&"posted".to_owned()));
	let last = line(&conversation, "last");
	let full = rooms.send(&last, rooms.base().await.unwrap()).await.unwrap_err();
	let code = rooms_application::failure::Failure::parse(&full.message).map(|failure| failure.code);
	assert_eq!(
		code,
		Some(rooms_application::failure::FailureCode::ReceiptsFull),
		"{full:?}"
	);
	assert_eq!(rooms.release(&posted, base).await.unwrap(), Handback::Taken);
	assert!(!rooms.held().await.unwrap().contains(&"posted".to_owned()));
	rooms.send(&last, rooms.base().await.unwrap()).await.unwrap();
	assert_eq!(rooms.observe(&posted, base).await.unwrap(), Outcome::Absent);
	assert_eq!(
		rooms.echoed(&posted, &Cursor::start()).await.unwrap(),
		Echo::Found,
		"the line of the receipt let go was not posted"
	);
}

/// The agent's actions and opens share the receipts' window, so enough of
/// them leave no place for a line and its send is refused before dispatch, as
/// the session refuses it. Keeping the lines does not make room.
#[tokio::test]
async fn actions_and_opens_fill_the_window_a_reply_needs() {
	let dir = Scratch::create("bot-files-window");
	let rooms = Files::open(&dir);
	let conversation = ConversationId::new("c");
	let line = |operation: &'static str| Outgoing {
		conversation: &conversation,
		text: "t",
		operation,
	};
	for operation in ["a", "b", "c"] {
		let base = rooms.base().await.unwrap();
		assert_eq!(rooms.send(&line(operation), base).await.unwrap(), Outcome::Committed);
		rooms.keep(&line(operation), base).await.unwrap();
	}
	let names = |prefix: &str, count: usize| -> String { (0..count).map(|n| format!("{prefix}{n}\n")).collect() };
	std::fs::write(dir.join("held-actions"), names("act", 3)).unwrap();
	std::fs::write(dir.join("held-opens"), names("open", MAX_EFFECTS - 4)).unwrap();
	let base = rooms.base().await.unwrap();
	assert_eq!(rooms.send(&line("fits"), base).await.unwrap(), Outcome::Committed);
	let error = rooms.send(&line("full"), base).await.unwrap_err();
	assert!(error.refused_before_dispatch, "a full window refuses before dispatch");
	assert!(error.to_string().contains("receipts-full"), "{error}");
}

/// A release of a receipt whose line its source kept answers kept, which the
/// bot reads as taken, and changes nothing: the line stays kept and a keep
/// asked again succeeds.
#[tokio::test]
async fn releasing_a_kept_receipt_changes_nothing() {
	let dir = Scratch::create("bot-files-kept-release");
	let rooms = Files::open(&dir);
	let conversation = ConversationId::new("c");
	let line = Outgoing {
		conversation: &conversation,
		text: "t",
		operation: "op1",
	};
	let base = rooms.base().await.unwrap();
	rooms.send(&line, base).await.unwrap();
	rooms.keep(&line, base).await.unwrap();
	assert_eq!(rooms.release(&line, base).await.unwrap(), Handback::Taken);
	assert!(
		!receipts::read(&dir).unwrap()[0].released,
		"the release left the kept receipt alone"
	);
	rooms.keep(&line, base).await.unwrap();
}

/// A list of held receipts that waits for a release file nobody writes fails
/// at its bound instead of spinning for ever.
#[tokio::test(start_paused = true)]
async fn a_held_list_that_waits_for_a_file_nobody_writes_fails() {
	let dir = Scratch::create("bot-files-held-wait");
	let rooms = Files::open(&dir);
	std::fs::write(dir.join("held-answers"), "wait\n").unwrap();
	let answer = tokio::time::timeout(HELD_WAIT * 2, rooms.held())
		.await
		.expect("the wait has a bound");
	assert_eq!(answer.unwrap_err().kind, RoomsErrorKind::Unreachable);
	assert!(dir.join("held-asked").exists());
}
