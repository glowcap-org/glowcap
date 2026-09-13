//! Host session service proofs: attach, directory reconnect, live rooms, history, and DMs.
use super::*;
use glowcap::{Argument, PendingWork};
use rooms_application::{grants::Access, session::snapshot::Snapshot};
use rooms_glowcap::{Value, routes::CheckpointRoutes};
use std::{
	path::PathBuf,
	sync::atomic::{AtomicU64, Ordering},
	time::Duration,
};
mod attach;
mod chat;
mod direct;
mod directories;
mod grants;
mod live_files;
mod live_managed;
mod live_ops;
mod live_ops_mutations;
mod live_share;
mod live_trace;
mod lost_source;
mod ops;
mod peer;
mod rooms;
mod rust_directory;
mod views;
use peer::DirectoryPeer;
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
	fn new() -> Self {
		let path = std::env::temp_dir().join(format!(
			"rooms-session-peer-{}-{}",
			std::process::id(),
			NEXT.fetch_add(1, Ordering::Relaxed)
		));
		std::fs::create_dir(&path).unwrap();
		Self(path)
	}
}
impl Drop for Temp {
	fn drop(&mut self) {
		let _ = std::fs::remove_dir_all(&self.0);
	}
}
fn parse_snapshot(reply: &Argument) -> Snapshot {
	let values: Vec<_> = reply.as_list().expect("snapshot list").iter().map(Value).collect();
	Snapshot::read(&values, &CheckpointRoutes).expect("valid snapshot")
}
fn tcp_config(state: PathBuf) -> Config {
	Config {
		state,
		transport: Transport::Tcp {
			bind: "127.0.0.1".into(),
			port: 0,
			announce: None,
		},
		checkpoint: None,
		readiness_file: None,
		relay_url: None,
	}
}
struct Running {
	stop: tokio::sync::oneshot::Sender<()>,
	task: tokio::task::JoinHandle<Result<(), Error>>,
	link: String,
}
async fn start_session(state: PathBuf) -> Running {
	let (stop, stopped) = tokio::sync::oneshot::channel();
	let (ready, link) = tokio::sync::oneshot::channel();
	let mut task = tokio::task::spawn_local(run(
		tcp_config(state),
		async {
			let _ = stopped.await;
		},
		|link| {
			ready.send(link.to_owned()).unwrap();
		},
		std::rc::Rc::new(|_| {}),
	));
	let link = tokio::select! {
		link = link => match link {
			Ok(link) => link,
			Err(_) => panic!("session startup failed: {:?}", task.await.unwrap()),
		},
		result = &mut task => panic!("session startup failed: {:?}", result.unwrap()),
	};
	Running { stop, task, link }
}
async fn stop_session(running: Running, session: glowcap::Session) {
	session.close(PendingWork::Cancel).await.unwrap();
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
}
async fn wait_directory(session: &glowcap::Session, root: &glowcap::Ref, id: &str) -> Snapshot {
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			let snapshot = parse_snapshot(&session.send(root, "snapshot", &[]).await.unwrap());
			if snapshot
				.connected_directories
				.as_slice()
				.iter()
				.any(|held| held.text().as_str() == Some(id))
			{
				return snapshot;
			}
			tokio::time::sleep(Duration::from_millis(20)).await;
		}
	})
	.await
	.expect("session connected its live directory")
}
async fn wait_room(session: &glowcap::Session, root: &glowcap::Ref, conversation: &str) {
	let mut last = String::new();
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			let snapshot = parse_snapshot(&session.send(root, "snapshot", &[]).await.unwrap());
			last = format!(
				"revision={} issues={:?} rooms={:?}",
				snapshot.revision.get(),
				snapshot
					.issues
					.as_slice()
					.iter()
					.map(|(subject, reason)| (subject.text().as_str(), reason.text().as_str()))
					.collect::<Vec<_>>(),
				snapshot
					.room_views
					.as_slice()
					.iter()
					.filter_map(|view| view.conversation_id.text().as_str())
					.collect::<Vec<_>>(),
			);
			if snapshot
				.room_views
				.as_slice()
				.iter()
				.any(|view| view.conversation_id.text().as_str() == Some(conversation))
			{
				return;
			}
			tokio::time::sleep(Duration::from_millis(20)).await;
		}
	})
	.await
	.unwrap_or_else(|_| panic!("session sat in the public room: {last}"));
}
async fn wait_direct(session: &glowcap::Session, root: &glowcap::Ref, conversation: &str) {
	let mut last = String::new();
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			let snapshot = parse_snapshot(&session.send(root, "snapshot", &[]).await.unwrap());
			last = format!(
				"revision={} directs={:?}",
				snapshot.revision.get(),
				snapshot
					.checkpoint
					.directs()
					.filter_map(|intent| intent.id.text().as_str().map(str::to_owned))
					.collect::<Vec<_>>(),
			);
			if snapshot
				.checkpoint
				.directs()
				.any(|intent| !intent.closed && intent.id.text().as_str() == Some(conversation))
			{
				return;
			}
			tokio::task::yield_now().await;
		}
	})
	.await
	.unwrap_or_else(|_| panic!("session intended the direct conversation: {last}"));
}
fn contains_text(value: &Argument, needle: &str) -> bool {
	match value {
		Argument::String(text) => text.contains(needle),
		Argument::List(values) => values.iter().any(|value| contains_text(value, needle)),
		_ => false,
	}
}
async fn adopt_admin(session: &glowcap::Session, root: &glowcap::Ref, id: &str) -> Snapshot {
	let snapshot = parse_snapshot(&session.send(root, "snapshot", &[]).await.unwrap());
	session
		.send(
			root,
			"adoptWorkspace",
			&[
				id.into(),
				Argument::Integer(0),
				snapshot.checkpoint.encode_for(Access::Admin).unwrap().into(),
			],
		)
		.await
		.unwrap();
	parse_snapshot(&session.send(root, "snapshot", &[]).await.unwrap())
}
async fn join_directory(
	session: &glowcap::Session,
	root: &glowcap::Ref,
	peer: &DirectoryPeer,
	operation: &str,
	revision: i64,
) -> (String, Snapshot) {
	use rooms_application::session::checkpoint::Routes;
	let directory = CheckpointRoutes.locator_authority(&peer.locator).unwrap();
	session
		.send(
			root,
			"command",
			&[
				operation.into(),
				Argument::Integer(revision),
				"joinDirectory".into(),
				serde_json::json!({
					"id": directory,
					"locator": peer.locator,
					"home": true,
					"nick": "alice",
					"standing": null
				})
				.to_string()
				.into(),
			],
		)
		.await
		.unwrap();
	let snapshot = wait_directory(session, root, directory.as_str()).await;
	(directory, snapshot)
}
/// Join the directory peer's `garden` room as `garden-room`, answering the
/// directory id the archive files the room's lines under.
async fn join_garden_room(session: &glowcap::Session, root: &glowcap::Ref, peer: &DirectoryPeer) -> String {
	adopt_admin(session, root, "adopt-files").await;
	let (directory, connected) = join_directory(session, root, peer, "join-dir", 1).await;
	session
		.send(
			root,
			"command",
			&[
				"join-room".into(),
				Argument::Integer(connected.revision.get() as i64),
				"joinRoom".into(),
				serde_json::json!({
					"locator": peer.locator,
					"nick": "alice",
					"conversation": {
						"kind": "room",
						"id": "garden-room",
						"directory": directory,
						"name": "garden",
						"held": false,
						"standing": null,
						"draft": ""
					}
				})
				.to_string()
				.into(),
			],
		)
		.await
		.unwrap();
	wait_room(session, root, "garden-room").await;
	directory
}
/// `sendFiles` arguments for one file whose bytes `blob` answers.
fn send_file_args(revision: i64, caption: &str, name: &str, size: usize, blob: glowcap::Ref) -> Vec<Argument> {
	vec![
		"file-operation".into(),
		Argument::Integer(revision),
		"garden-room".into(),
		caption.into(),
		"[]".into(),
		"file".into(),
		name.into(),
		"text/plain".into(),
		Argument::Integer(size as i64),
		blob.into(),
		Argument::Integer(0),
		Argument::Integer(0),
	]
}
/// The archived `garden-room` line containing `needle`, once the session has
/// filed it.
async fn wait_history_row(session: &glowcap::Session, root: &glowcap::Ref, directory: &str, needle: &str) -> Argument {
	tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			let history = session
				.send(
					root,
					"readHistory",
					&["room".into(), directory.into(), "garden-room".into()],
				)
				.await
				.unwrap();
			if let Argument::List(rows) = &history
				&& let Some(row) = rows.iter().find(|row| contains_text(row, needle))
			{
				return row.clone();
			}
			tokio::task::yield_now().await;
		}
	})
	.await
	.expect("session archived the file line")
}
#[test]
fn session_peer_configuration_requires_state_and_resolves_explicit_transport_options() {
	let parse = |args: &[&str]| Config::parse(args.iter().map(|s| s.to_string()), |_| None);
	assert!(parse(&[]).is_err());
	assert!(parse(&["--help"]).unwrap().is_none());
	assert!(matches!(
		parse(&["--state=place"]).unwrap().unwrap().transport,
		Transport::Iroh(glowcap::iroh::Reachability::Discovery)
	));
	let tcp = parse(&["--state=place", "--transport=tcp", "--port=9"])
		.unwrap()
		.unwrap();
	assert!(matches!(tcp.transport, Transport::Tcp { port: 9, .. }));
	assert_eq!(tcp.readiness_path(), PathBuf::from("place/admin.sturdyref"));
	assert!(parse(&["--state=place", "--transport=no"]).is_err());
	assert!(parse(&["--state=place", "--state=again"]).is_err());
}
