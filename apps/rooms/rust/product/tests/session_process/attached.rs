//! The attached view drives real session processes through a Rooms server
//! over loopback CapTP, as a bot host would. Every wait has a deadline.
use super::session_rig::{Fixture, attach, call, host, run_within, text_arrived};
use super::*;
use glowcap::{CaptpVersion, ConnectOptions, PendingWork};
use rooms_application::content::{
	permissions::Permission,
	session::{self, Preset, Terms},
};
use rooms_glowcap::client::{
	Client,
	access::{Control, Issuance},
};
use rooms_platform::HostPlatform;
use rooms_services::session::attached::{
	Change, ClientError, EffectStatus, Error, Event, Files, Grants, Holder, Kind, Notice, Opened, Outgoing, Reach,
	State, View,
};
use serde_json::json;
/// How long a post with files waits for the room to hold them.
const WAIT_MS: u64 = 60_000;
use std::path::Path;

const ROOM: &str = "attached-room";

fn start(name: &str) -> Fixture {
	Fixture::start(name, &["attached-one", "attached-two"], ROOM)
}
fn run<F: std::future::Future>(scenario: F) -> F::Output {
	run_within(Duration::from_secs(60), scenario)
}
/// Read from `cursor` until an event satisfies `wanted`, within ten seconds.
pub(super) async fn until(view: &View<HostPlatform>, cursor: &mut String, wanted: impl Fn(&Event) -> bool) -> Event {
	let deadline = Instant::now() + Duration::from_secs(10);
	loop {
		let batch = view.events(cursor, true).await.unwrap();
		assert!(!batch.gap && !batch.unavailable, "{batch:?}");
		cursor.clone_from(&batch.cursor);
		if let Some(event) = batch.events.into_iter().find(|event| wanted(event)) {
			return event;
		}
		assert!(Instant::now() < deadline, "the awaited event never arrived");
	}
}
pub(super) fn said(text: &'static str) -> impl Fn(&Event) -> bool {
	move |event| matches!(&event.notice, Notice::Line(line) if line.text == text)
}
fn with_file(text: &'static str) -> impl Fn(&Event) -> bool {
	move |event| said(text)(event) && !event.attachments.is_empty()
}
fn open(path: &std::path::Path) -> Outgoing {
	Outgoing::open(path).unwrap()
}
fn bytes(seed: u8, length: usize) -> Vec<u8> {
	(0..length)
		.map(|index| (index as u8).wrapping_mul(31).wrapping_add(seed))
		.collect()
}

#[test]
fn a_view_says_a_line_and_reads_lines_that_mention_it() {
	let fixture = start("attached-say");
	let (one, two) = (&fixture.peers[0], &fixture.peers[1]);
	run(async {
		let runtime = host().await;
		let view = attach(&runtime, &one.link).await;
		let room = fixture.room_id(0);
		let sent = view.say("attached-say-1", &room, "a line from the view").await.unwrap();
		assert_eq!(sent.status, EffectStatus::Committed);
		text_arrived(&two.state, "a line from the view");
		// The same operation again is the same effect, not a second line.
		let again = view
			.command(
				"attached-say-1",
				sent.base,
				"say",
				&[room.clone(), "a line from the view".into()],
			)
			.await
			.unwrap();
		assert_eq!(again, EffectStatus::Committed);
		assert_eq!(
			view.observe(
				"attached-say-1",
				sent.base,
				"say",
				&[room.clone(), "a line from the view".into()]
			)
			.await
			.unwrap(),
			EffectStatus::Committed
		);
		let mut cursor = String::new();
		for (text, member, everyone) in [
			("@attached-one are you there", true, false),
			("@here standup", false, true),
			("no mention at all", false, false),
		] {
			let sent = call(&two.state, "reply", json!({"room":[ROOM],"text":[text]}));
			assert_eq!(sent["status"], "committed");
			let event = until(&view, &mut cursor, said(text)).await;
			assert_eq!(event.conversation.kind, Kind::Room);
			assert_eq!(
				(event.mentions.member, event.mentions.room),
				(member, everyone),
				"{text}"
			);
		}
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

#[test]
fn files_move_both_ways_by_exact_bytes_and_fetch_never_overwrites() {
	let fixture = start("attached-files");
	let scratch = &fixture.temp;
	run(async {
		let runtime = host().await;
		let one = attach(&runtime, &fixture.peers[0].link).await;
		let two = attach(&runtime, &fixture.peers[1].link).await;
		let room = fixture.room_id(0);
		let mut one_cursor = String::new();
		let mut two_cursor = String::new();
		// Past one span, so a fetch reads more than once.
		let small = scratch.join("small.txt");
		let large = scratch.join("large.bin");
		std::fs::write(&small, bytes(1, 700)).unwrap();
		std::fs::write(&large, bytes(2, 150_000)).unwrap();
		let sent = one
			.send_files(
				"attached-files-1",
				&room,
				"from one",
				&[open(&small), open(&large)],
				WAIT_MS,
			)
			.await
			.unwrap();
		assert_eq!(sent.sent.status, EffectStatus::Committed);
		assert_eq!(sent.files, Files::Complete);
		let event = until(&two, &mut two_cursor, with_file("from one")).await;
		assert_eq!(event.attachments.len(), 2);
		let received = scratch.join("received");
		std::fs::create_dir(&received).unwrap();
		for (attachment, original) in event.attachments.iter().zip([&small, &large]) {
			let destination = received.join(&attachment.name);
			let written = two.fetch(attachment, &destination).await.unwrap();
			assert_eq!(written, attachment.size as u64);
			assert_eq!(std::fs::read(&destination).unwrap(), std::fs::read(original).unwrap());
		}
		// A second fetch refuses, keeps the first bytes, and leaves no partial.
		let first = &event.attachments[0];
		let existing = received.join(&first.name);
		assert!(matches!(two.fetch(first, &existing).await, Err(Error::Exists(_))));
		assert_eq!(std::fs::read(&existing).unwrap(), std::fs::read(&small).unwrap());
		assert_eq!(
			std::fs::read_dir(&received).unwrap().count(),
			2,
			"a partial file remained"
		);
		// The other direction.
		let back = scratch.join("back.bin");
		std::fs::write(&back, bytes(3, 90_000)).unwrap();
		let sent = two
			.send_files(
				"attached-files-2",
				&fixture.room_id(1),
				"from two",
				&[open(&back)],
				WAIT_MS,
			)
			.await
			.unwrap();
		assert_eq!(sent.sent.status, EffectStatus::Committed);
		assert_eq!(sent.files, Files::Complete);
		let event = until(&one, &mut one_cursor, with_file("from two")).await;
		let destination = received.join("back-received.bin");
		one.fetch(&event.attachments[0], &destination).await.unwrap();
		assert_eq!(std::fs::read(&destination).unwrap(), std::fs::read(&back).unwrap());
		// A directory is no source, and nothing was posted for it.
		let refused = one
			.send_files("attached-files-3", &room, "x", &[open(&received)], WAIT_MS)
			.await;
		assert!(matches!(refused, Err(Error::Input(_))), "{refused:?}");
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

#[test]
fn paused_and_revoked_access_are_typed_and_an_unreachable_peer_is_not() {
	let mut fixture = start("attached-access");
	let management = std::fs::read_to_string(fixture.peers[0].state.join("management.sturdyref")).unwrap();
	let link = fixture.peers[0].link.clone();
	run(async {
		let runtime = host().await;
		let parsed = |link: &str| glowcap::parse_sturdyref(link.trim(), CaptpVersion::V1_0).unwrap();
		let (use_link, management_link) = (parsed(&link), parsed(&management));
		let connection = runtime
			.connect(&use_link.locator, ConnectOptions::default())
			.await
			.unwrap();
		let control = connection
			.fetch(std::str::from_utf8(&management_link.swissnum).unwrap())
			.await
			.unwrap();
		let client = Client::new(connection, HostPlatform);
		let control = Control::new(client.clone(), control);
		let observer = rooms_glowcap::policy::descriptor()
			.unwrap()
			.value_for_kind(session::KIND, &[Permission::ObserveWorkspace.key()], &[])
			.unwrap();
		let revision = async |control: &Control<HostPlatform>| {
			let state = control.describe().await.unwrap();
			let glowcap::loam::ControlDescription::Available(view) = state.view() else {
				panic!("held management unavailable")
			};
			view.revision
		};
		let issue = async |label: &str, paused: bool| {
			let issuance = Issuance::new(
				observer.with_ceiling(observer),
				control.derivation_sequence().await.unwrap(),
				revision(&control).await,
				0,
				glowcap::loam::ControlPowers {
					revoke: true,
					pause: true,
					resume: true,
					..Default::default()
				},
				label,
				paused,
			);
			control.issue(&issuance).await.unwrap()
		};
		// Issued paused, then resumed, then paused again, then revoked.
		let issued = issue("paused at issue", true).await;
		let child = Control::new(client.clone(), issued.control);
		assert!(matches!(
			View::attach_reference(client.clone(), issued.access.clone()).await,
			Err(Error::Paused)
		));
		child.resume(revision(&child).await).await.unwrap();
		let view = View::attach_reference(client.clone(), issued.access).await.unwrap();
		assert!(view.events("", false).await.is_ok());
		child.pause(revision(&child).await).await.unwrap();
		assert!(matches!(view.events("", false).await, Err(Error::Paused)));
		// The ask of whose receipt an operation is reads the access the same way,
		// so a start that asks through it waits or ends as for any read.
		assert!(matches!(view.holder("attached-access-asked").await, Err(Error::Paused)));
		child.resume(revision(&child).await).await.unwrap();
		assert!(view.events("", false).await.is_ok());
		assert!(matches!(view.holder("attached-access-asked").await, Ok(Holder::Nobody)));
		// Read-only access cannot write: a refusal, not an unknown outcome.
		let written = view.say("attached-access-write", "any", "no").await;
		assert!(matches!(written, Err(Error::Peer(_))), "{written:?}");
		child.revoke(revision(&child).await).await.unwrap();
		assert!(matches!(view.events("", false).await, Err(Error::Revoked)));
		assert!(matches!(
			view.holder("attached-access-asked").await,
			Err(Error::Revoked)
		));
		let again = issue("revoked later", false).await;
		let revoked = Control::new(client.clone(), again.control);
		revoked.revoke(revision(&revoked).await).await.unwrap();
		assert!(matches!(
			View::attach_reference(client, again.access).await,
			Err(Error::Revoked)
		));
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	// Peer gone: attaching again to the same link is unreachable, and says so.
	fixture.peers.remove(0).process.signal("-TERM");
	run(async {
		let runtime = host().await;
		let attached = View::attach(&runtime, HostPlatform, &link).await;
		assert!(
			matches!(attached, Err(Error::Unreachable(ClientError::Binding(_)))),
			"{:?}",
			attached.err()
		);
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

/// A link whose publication the session does not hold is the peer's answer
/// that it is gone, read from the fetch's typed cause, and the only fetch
/// answer that is `Refused`.
#[test]
fn a_link_the_session_does_not_hold_is_refused() {
	let fixture = start("attached-unknown-link");
	// Change one character of the swissnum, which ends where the hints begin.
	let link = fixture.peers[0].link.clone();
	let end = link.find('?').expect("a link carries hints after its swissnum");
	let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
	let at = end - 2;
	let value = alphabet.iter().position(|&c| c == link.as_bytes()[at]).unwrap();
	let mut bytes = link.into_bytes();
	bytes[at] = alphabet[(value + 1) % 64];
	let link = String::from_utf8(bytes).unwrap();
	run(async {
		let runtime = host().await;
		let attached = View::attach(&runtime, HostPlatform, &link).await;
		assert!(matches!(attached, Err(Error::Refused)), "{:?}", attached.err());
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

#[test]
fn a_cursor_resumes_after_reattach_without_duplicates_or_a_false_gap() {
	let fixture = start("attached-resume");
	let two = &fixture.peers[1];
	run(async {
		let runtime = host().await;
		let view = attach(&runtime, &fixture.peers[0].link).await;
		let mut cursor = String::new();
		for text in ["resume one", "resume two"] {
			call(&two.state, "reply", json!({"room":[ROOM],"text":[text]}));
			until(&view, &mut cursor, said(text)).await;
		}
		let persisted = cursor.clone();
		drop(view);
		runtime.close(PendingWork::Cancel).await.unwrap();
		call(&two.state, "reply", json!({"room":[ROOM],"text":["resume three"]}));
		call(&two.state, "reply", json!({"room":[ROOM],"text":["resume four"]}));
		// A fresh host and view resume from the saved cursor alone.
		let runtime = host().await;
		let view = attach(&runtime, &fixture.peers[0].link).await;
		let mut texts = Vec::new();
		let mut cursor = persisted.clone();
		let deadline = Instant::now() + Duration::from_secs(10);
		while texts.len() < 2 {
			let batch = view.events(&cursor, true).await.unwrap();
			assert!(!batch.gap && !batch.unavailable);
			cursor = batch.cursor;
			texts.extend(batch.events.into_iter().filter_map(|event| match event.notice {
				Notice::Line(line) => Some(line.text),
				Notice::Other(_) => None,
			}));
			assert!(Instant::now() < deadline, "resume stalled at {texts:?}");
		}
		assert_eq!(texts, ["resume three", "resume four"]);
		// Caught up: an idle read returns no events and the same position.
		let idle = view.events(&cursor, false).await.unwrap();
		assert!(idle.events.is_empty() && !idle.gap);
		assert_eq!(idle.cursor, cursor);
		// A cursor the session never issued is refused, never read as a gap.
		assert!(view.events("not-a-cursor", false).await.is_err());
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

fn changed(change: Change, text: &'static str) -> impl Fn(&Event) -> bool {
	move |event| matches!(&event.notice, Notice::Line(line) if line.change == change && (text.is_empty() || line.text == text))
}
async fn edit(view: &View<HostPlatform>, operation: &str, room: &str, id: u64, text: &str) {
	let base = view.revision().await.unwrap();
	let status = view
		.command(operation, base, "editLine", &[room.into(), id.to_string(), text.into()])
		.await
		.unwrap();
	assert_eq!(status, EffectStatus::Committed, "{operation}");
}

#[test]
fn a_line_said_through_the_view_stays_editable_and_withdrawable_across_attaches() {
	let fixture = start("attached-lines");
	let (one, two) = (&fixture.peers[0], &fixture.peers[1]);
	run(async {
		let runtime = host().await;
		let view = attach(&runtime, &one.link).await;
		let watcher = attach(&runtime, &two.link).await;
		let mut watched = String::new();
		let room = fixture.room_id(0);
		let sent = view.say("lines-say", &room, "first draft").await.unwrap();
		assert_eq!(sent.status, EffectStatus::Committed);
		let mut own = String::new();
		let event = until(&view, &mut own, said("first draft")).await;
		let Notice::Line(line) = event.notice else {
			panic!("the view saw no line")
		};
		let id = line.id.expect("the session numbers its own lines");
		until(&watcher, &mut watched, said("first draft")).await;
		edit(&view, "lines-edit-1", &room, id, "second draft").await;
		until(&watcher, &mut watched, changed(Change::Edited, "second draft")).await;
		// A new view on the same link edits the same line: the session holds it.
		drop(view);
		let view = attach(&runtime, &one.link).await;
		edit(&view, "lines-edit-2", &room, id, "third draft").await;
		until(&watcher, &mut watched, changed(Change::Edited, "third draft")).await;
		let base = view.revision().await.unwrap();
		let status = view
			.command("lines-withdraw", base, "withdrawLine", &[room.clone(), id.to_string()])
			.await
			.unwrap();
		assert_eq!(status, EffectStatus::Committed);
		until(&watcher, &mut watched, changed(Change::Withdrawn, "")).await;
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

#[test]
fn issued_access_attaches_from_another_host_and_follows_pause_resume_and_revoke() {
	let fixture = start("attached-grants");
	let (one, two) = (&fixture.peers[0], &fixture.peers[1]);
	let management = std::fs::read_to_string(one.state.join("management.sturdyref")).unwrap();
	run(async {
		let issuer = host().await;
		let grants = Grants::attach(&issuer, HostPlatform, &management).await.unwrap();
		let interact = Terms::new(Preset::Collaborator.values()).unwrap();
		let observe = Terms::new(Preset::Observer.values()).unwrap();
		let issued = grants.issue("the bot", &interact).await.unwrap();
		let watching = grants.issue("a reader", &observe).await.unwrap();
		let held = grants.grant(&issued.name).await.unwrap();
		assert_eq!(
			(held.label.as_str(), &held.rights, held.state),
			("the bot", &interact, State::Active)
		);
		let listed = grants.list().await.unwrap();
		let row = |label: &str| listed.iter().find(|grant| grant.label == label).cloned();
		assert_eq!(row("the bot").unwrap().id, held.id);
		assert_eq!(row("a reader").unwrap().rights, observe);
		// Another Host attaches with the returned link alone and writes.
		let holder = host().await;
		let view = attach(&holder, &issued.link).await;
		let room = fixture.room_id(0);
		let said = view.say("grants-say-1", &room, "from issued access").await.unwrap();
		assert_eq!(said.status, EffectStatus::Committed);
		text_arrived(&two.state, "from issued access");
		// One Host holds one connection to a session, so a second holder is a third Host.
		let second = host().await;
		let reader = attach(&second, &watching.link).await;
		assert!(matches!(
			reader.say("grants-reader", &room, "no").await,
			Err(Error::Peer(_))
		));
		let state = async |name: &str| grants.grant(name).await.unwrap().state;
		grants.pause(&issued.name).await.unwrap();
		assert!(matches!(
			view.say("grants-say-2", &room, "paused").await,
			Err(Error::Paused)
		));
		assert_eq!(state(&issued.name).await, State::Paused);
		assert_eq!(state(&watching.name).await, State::Active);
		grants.resume(&issued.name).await.unwrap();
		let again = view.say("grants-say-3", &room, "resumed").await.unwrap();
		assert_eq!(again.status, EffectStatus::Committed);
		assert_eq!(state(&issued.name).await, State::Active);
		grants.revoke(&issued.name).await.unwrap();
		assert!(matches!(
			view.say("grants-say-4", &room, "revoked").await,
			Err(Error::Revoked)
		));
		drop(view);
		let reattached = View::attach(&holder, HostPlatform, &issued.link).await;
		assert!(matches!(reattached, Err(Error::Revoked)), "{:?}", reattached.err());
		let listed = grants.list().await.unwrap();
		let states: Vec<_> = ["the bot", "a reader"]
			.iter()
			.map(|label| listed.iter().find(|grant| grant.label == *label).unwrap().state)
			.collect();
		assert_eq!(states, [State::Revoked, State::Active]);
		assert!(matches!(grants.pause(&issued.name).await, Err(Error::Revoked)));
		grants
			.revoke(&issued.name)
			.await
			.expect("revoking a revoked access succeeds");
		second.close(PendingWork::Cancel).await.unwrap();
		holder.close(PendingWork::Cancel).await.unwrap();
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

/// The first directory the session holds.
pub(super) async fn first_directory(view: &View<HostPlatform>) -> String {
	let snapshot = view.snapshot().await.unwrap();
	snapshot
		.intent
		.directories
		.as_slice()
		.iter()
		.find_map(|row| row.id.text().as_str().map(str::to_owned))
		.expect("the session has a directory")
}

/// Two callers of `operation` held both past their first look at whether it
/// was adopted before either adopts. Both must report the open as their own,
/// name one conversation, and leave its route carrying a line.
async fn open_twice(view: &View<HostPlatform>, directory: &str, operation: &str, peer: &Path) -> String {
	let Reach::Introduce(introduction) = view.reach_direct(directory, "attached-two").await.unwrap() else {
		panic!("the peer was already reached")
	};
	let base = view.revision().await.unwrap();
	let assert_met = rooms_services::session::attached::meet_before_keeping_direct(operation, 2);
	let (first, second) = tokio::join!(
		view.introduce(operation, Some(base), &introduction),
		view.introduce(operation, Some(base), &introduction)
	);
	assert_met();
	let conversation = |opened: Result<Opened, Error>| match opened {
		Ok(Opened::Opened { conversation, .. }) => conversation,
		other => panic!("a caller did not report the open as its own: {other:?}"),
	};
	let (first, second) = (conversation(first), conversation(second));
	assert_eq!(first, second);
	let reached = view.reach_direct(directory, "attached-two").await.unwrap();
	assert_eq!(
		reached,
		Reach::Open(first.clone()),
		"the open conversation lost its route"
	);
	let text = format!("through the route of {operation}");
	let said = view.say(&format!("{operation}-say"), &first, &text).await.unwrap();
	assert_eq!(said.status, EffectStatus::Committed);
	text_arrived(peer, &text);
	first
}

/// Two callers of one operation, such as a turn and a look at its note, open
/// a direct conversation that was never open: the row takes the operation as
/// its id.
#[test]
fn two_callers_of_one_first_open_both_report_it_and_the_route_stays_held() {
	let fixture = start("attached-two-first");
	let (one, two) = (&fixture.peers[0], &fixture.peers[1]);
	run(async {
		let holder = host().await;
		let view = attach(&holder, &one.link).await;
		let directory = first_directory(&view).await;
		let opened = open_twice(&view, &directory, "two-callers-first", &two.state).await;
		assert_eq!(
			opened, "two-callers-first",
			"a first open takes its operation as its id"
		);
		drop(view);
		holder.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

/// The same, for a closed conversation reopened: its row keeps its old id, so
/// the id cannot say which operation made it.
#[test]
fn two_callers_of_one_reopen_both_report_it_and_the_route_stays_held() {
	let fixture = start("attached-two-reopen");
	let (one, two) = (&fixture.peers[0], &fixture.peers[1]);
	run(async {
		let holder = host().await;
		let view = attach(&holder, &one.link).await;
		let directory = first_directory(&view).await;
		let Reach::Introduce(introduction) = view.reach_direct(&directory, "attached-two").await.unwrap() else {
			panic!("the peer was already reached")
		};
		let base = view.revision().await.unwrap();
		let first = match view.introduce("two-callers-before", Some(base), &introduction).await {
			Ok(Opened::Opened { conversation, .. }) => conversation,
			other => panic!("the first open did not open: {other:?}"),
		};
		let base = view.revision().await.unwrap();
		let closed = view
			.command("two-callers-close", base, "closeDirect", std::slice::from_ref(&first))
			.await
			.unwrap();
		assert_eq!(closed, EffectStatus::Committed);
		let deadline = Instant::now() + Duration::from_secs(10);
		// A read the session is too busy to answer is asked again.
		while !matches!(
			view.reach_direct(&directory, "attached-two").await,
			Ok(Reach::Introduce(_))
		) {
			assert!(Instant::now() < deadline, "the closed conversation stayed open");
			tokio::time::sleep(Duration::from_millis(250)).await;
		}
		let reopened = open_twice(&view, &directory, "two-callers-again", &two.state).await;
		assert_eq!(reopened, first, "a reopened conversation keeps its id");
		drop(view);
		holder.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}
