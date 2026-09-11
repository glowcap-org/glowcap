use super::*;
use crate::documents::Completion;
use crate::documents::{SessionDocuments, SessionOwners};
use rooms_application::{grants::Access, session::state::Text};
use rooms_application::{
	session::{
		checkpoint::{
			commands::{results, Command},
			Checkpoint,
		},
		state::{self, Impact},
	},
	text::DocumentText,
};
use rooms_glowcap::routes::CheckpointRoutes;
use std::{
	path::PathBuf,
	sync::atomic::{AtomicU64, Ordering},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
	fn new() -> Self {
		let path = std::env::temp_dir().join(format!(
			"rooms-session-state-{}-{}",
			std::process::id(),
			NEXT.fetch_add(1, Ordering::Relaxed)
		));
		std::fs::create_dir(&path).unwrap();
		Self(path)
	}
}
impl Drop for Temp {
	fn drop(&mut self) {
		std::fs::remove_dir_all(&self.0).unwrap();
	}
}
async fn owner(path: &std::path::Path) -> DurableSession {
	let SessionOwners {
		state,
		grants,
		bridge_secrets,
	} = SessionDocuments::open(path).await.unwrap().into_owners();
	drop(grants);
	drop(bridge_secrets);
	state
}
fn text<const N: usize>(s: &str) -> Text<N, true> {
	Text::new(s.into()).unwrap()
}
fn checkpoint(value: &DocumentText) -> Checkpoint {
	let mut state: serde_json::Value =
		serde_json::from_str(&Checkpoint::empty().encode_for(Access::Admin).unwrap()).unwrap();
	state["standing"] = serde_json::from_str(&serde_json::to_string(value).unwrap()).unwrap();
	Checkpoint::decode(&state.to_string(), &CheckpointRoutes).unwrap()
}
#[tokio::test]
async fn commands_preserve_multiple_rooms_and_retry_identity_after_restart() {
	let temp = Temp::new();
	let mut session = owner(&temp.0).await;
	assert!(matches!(session.load().await.unwrap(), LoadStatus::Ready));
	let join = |directory: &str, id: &str, name: &str| -> Vec<DocumentText> {
		vec![serde_json::json!({"locator":directory,"nick":"ada","conversation":{
			"kind":"room","id":id,"directory":directory,"name":name,"held":false,
			"standing":null,"draft":""}})
		.to_string()
		.into()]
	};
	let first = join("ocapn://first.id", "one", "general");
	let second = join("ocapn://first.id", "two", "other");
	let third = join("ocapn://second.id", "three", "general");
	for (at, args) in [&first, &second, &third].into_iter().enumerate() {
		let (revision, change) = session
			.command(text(&format!("join-{at}")), at as u64, Command::JoinRoom, args, &())
			.await
			.unwrap();
		assert_eq!(revision, at as u64 + 1);
		assert_eq!(change.unwrap().checkpoint, Some(Impact::Realization));
	}
	let snapshot = |s: &DurableSession| -> serde_json::Value {
		serde_json::from_str(
			&s.state()
				.unwrap()
				.checkpoint()
				.unwrap()
				.encode_for(Access::Admin)
				.unwrap(),
		)
		.unwrap()
	};
	let before = snapshot(&session);
	assert_eq!(before["directories"].as_array().unwrap().len(), 2);
	assert_eq!(before["conversations"].as_array().unwrap().len(), 3);
	drop(session);
	session = owner(&temp.0).await;
	assert!(matches!(session.load().await.unwrap(), LoadStatus::Ready));
	assert_eq!(snapshot(&session), before);
	assert_eq!(
		session
			.command(text("join-0"), 999, Command::JoinRoom, &first, &())
			.await
			.unwrap(),
		(1, None)
	);
	// Replaying a completed join must not select that room or update its route.
	assert_eq!(snapshot(&session), before);
	let changed = join("ocapn://first.id", "one", "changed");
	assert!(matches!(
		session
			.command(text("join-0"), 3, Command::JoinRoom, &changed, &())
			.await,
		Err(Error::State(state::Error::Reused))
	));
	session
		.command(
			text("retire"),
			3,
			Command::LeaveDirectory,
			&["ocapn://first.id".into()],
			&(),
		)
		.await
		.unwrap();
	let after = snapshot(&session);
	assert_eq!(after["directories"].as_array().unwrap().len(), 1);
	assert_eq!(after["conversations"].as_array().unwrap().len(), 1);
	assert_eq!(after["conversations"][0]["id"], "three");
	assert_eq!(after["active"], "three");
	assert_eq!(session.state().unwrap().revision().unwrap(), 4);
}
#[tokio::test]
async fn sessions_keep_distinct_identities_and_restore_every_result_boundary() {
	let temp = Temp::new();
	let other = Temp::new();
	let mut a = owner(&temp.0).await;
	let mut b = owner(&other.0).await;
	assert!(matches!(a.load().await.unwrap(), LoadStatus::Ready));
	assert!(matches!(b.load().await.unwrap(), LoadStatus::Ready));
	let identity = *a.state().unwrap().identity_seed().unwrap();
	let entropy = *a.state().unwrap().session_entropy().unwrap();
	assert_ne!(identity, *b.state().unwrap().identity_seed().unwrap());
	a.command(
		text("join"),
		0,
		Command::JoinRoom,
		&[serde_json::json!({
		"locator":"ocapn://directory.id", "nick":"ada", "conversation":{
			"kind":"room", "id":"room", "directory":"ocapn://directory.id", "name":"general",
			"held":false, "standing":null, "draft":""}})
		.to_string()
		.into()],
		&(),
	)
	.await
	.unwrap();
	let plan = results::Command::EnsureRoomLink
		.prepare(
			a.state().unwrap().checkpoint().unwrap(),
			&["room".into()],
			&CheckpointRoutes,
			false,
		)
		.unwrap();
	a.command(
		text("draft"),
		1,
		Command::SetDraft,
		&["room".into(), "concurrent draft".into()],
		&(),
	)
	.await
	.unwrap();
	let before_refusal = std::fs::read(temp.0.join("effects.json")).unwrap();
	assert!(a
		.prepare_plan(text("stale-plan"), 2, &"stale".into(), &plan)
		.await
		.is_err());
	assert_eq!(std::fs::read(temp.0.join("effects.json")).unwrap(), before_refusal);
	let plan = plan
		.resume(a.state().unwrap().checkpoint().unwrap(), &CheckpointRoutes)
		.unwrap();
	let id = text("result");
	let material = "material".into();
	assert!(matches!(
		a.prepare_plan(id.clone(), 2, &material, &plan).await.unwrap().0,
		ResultStatus::Prepared
	));
	let link = glowcap::format_sturdyref(
		&glowcap::parse_locator("ocapn://directory.id").unwrap(),
		b"room-link",
		glowcap::CaptpVersion::V1_0,
	)
	.unwrap();
	a.record_result(
		&id,
		Some(&material),
		text(&serde_json::json!({"roomLink": link}).to_string()),
	)
	.await
	.unwrap();
	let mut changes = vec![];
	loop {
		drop(a);
		a = owner(&temp.0).await;
		let loaded = a.load().await.unwrap();
		assert!(match loaded {
			LoadStatus::Ready => a.state().unwrap().pending_ids().unwrap().len() == 0,
			LoadStatus::RecoverResult(ref pending) => pending == &id,
		});
		assert_eq!(a.state().unwrap().identity_seed().unwrap(), &identity);
		assert_eq!(a.state().unwrap().session_entropy().unwrap(), &entropy);
		let (revision, change) = a.finish_result(&id).await.unwrap();
		if let Some(change) = change {
			changes.push(change.checkpoint);
		} else {
			assert_eq!(revision, 3);
			break;
		}
	}
	assert_eq!(changes, vec![None, Some(Impact::Realization), None]);
	assert_eq!(a.state().unwrap().pending_ids().unwrap().len(), 0);
	assert_eq!(b.state().unwrap().revision().unwrap(), 0);
	assert!(matches!(
		a.prepare_plan(id, 2, &material, &plan).await.unwrap().0,
		ResultStatus::Committed { revision: 3, .. }
	));
}
#[tokio::test]
async fn initialization_resumes_only_an_empty_unpublished_effect_ledger() {
	let temp = Temp::new();
	let mut docs = SessionDocuments::open(&temp.0).await.unwrap();
	docs.effects
		.replace(b"{\"version\":1,\"recent\":[],\"pending\":[]}\n".to_vec())
		.await
		.unwrap();
	drop(docs);
	let mut session = owner(&temp.0).await;
	assert!(matches!(session.load().await.unwrap(), LoadStatus::Ready));
	session
		.prepare_ordinary(text("effect"), 0, &"material".into())
		.await
		.unwrap();
	drop(session);
	std::fs::remove_file(temp.0.join("session.json")).unwrap();
	let before = std::fs::read(temp.0.join("effects.json")).unwrap();
	let mut session = owner(&temp.0).await;
	assert!(matches!(session.load().await, Err(Error::OrphanedEffects)));
	assert_eq!(std::fs::read(temp.0.join("effects.json")).unwrap(), before);
	assert!(!temp.0.join("session.json").exists());
}
#[tokio::test]
async fn load_refuses_unknown_or_malformed_result_intent_without_rewriting_it() {
	for (kind, intent) in [("unknown", "{}"), ("room-link", "{}")] {
		let temp = Temp::new();
		let mut session = owner(&temp.0).await;
		assert!(matches!(session.load().await.unwrap(), LoadStatus::Ready));
		// Emulate a persisted document from a different or damaged application.
		// The public API accepts a validated Plan, never arbitrary kinds. Create
		// an ordinary digest through that API, then damage the stored row itself.
		session
			.prepare_ordinary(text("pending"), 0, &"material".into())
			.await
			.unwrap();
		drop(session);
		let path = temp.0.join("effects.json");
		let mut document: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
		let row = document["pending"][0].as_object_mut().unwrap();
		row.remove("subject");
		for (key, value) in [
			("type", serde_json::json!("result")),
			("resultKind", serde_json::json!(kind)),
			("baseRevision", serde_json::json!(0)),
			("intent", serde_json::json!(intent)),
			("result", serde_json::Value::Null),
			("marker", serde_json::Value::Null),
		] {
			row.insert(key.into(), value);
		}
		std::fs::write(path, serde_json::to_vec(&document).unwrap()).unwrap();
		let checkpoint = std::fs::read(temp.0.join("session.json")).unwrap();
		let effects = std::fs::read(temp.0.join("effects.json")).unwrap();
		let mut session = owner(&temp.0).await;
		assert!(session.load().await.is_err());
		assert!(matches!(session.state(), Err(Error::Unloaded)));
		assert_eq!(std::fs::read(temp.0.join("session.json")).unwrap(), checkpoint);
		assert_eq!(std::fs::read(temp.0.join("effects.json")).unwrap(), effects);
	}
}
#[test]
fn cancelled_mutation_requires_worker_retirement_then_restore() {
	use std::{
		future::Future,
		sync::mpsc,
		task::{Context, Poll, Waker},
	};
	tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.max_blocking_threads(1)
		.build()
		.unwrap()
		.block_on(async {
			let temp = Temp::new();
			let mut session = owner(&temp.0).await;
			assert!(matches!(session.load().await.unwrap(), LoadStatus::Ready));
			let (started, observed) = tokio::sync::oneshot::channel();
			let (release, wait) = mpsc::channel();
			let blocker = tokio::task::spawn_blocking(move || {
				started.send(()).unwrap();
				wait.recv().unwrap();
			});
			observed.await.unwrap();
			let material = "mutation".into();
			let view = session.view();
			{
				let mut future = Box::pin(session.mutate(text("change"), 0, &material, Impact::Realization, |_| {
					Ok(checkpoint(&"after".into()))
				}));
				assert!(matches!(
					future.as_mut().poll(&mut Context::from_waker(Waker::noop())),
					Poll::Pending
				));
				assert_eq!(view.read(|s| s.revision()).unwrap().unwrap(), 0);
			}
			assert!(matches!(
				session.state().unwrap().revision(),
				Err(state::Error::RecoveryRequired)
			));
			assert!(matches!(session.load().await, Err(Error::Pending)));
			release.send(()).unwrap();
			blocker.await.unwrap();
			let [checkpoint, effects] = session.finish_pending().await;
			assert!(matches!(checkpoint, Some(Completion::Write(Ok(())))));
			assert!(effects.is_none());
			assert!(matches!(session.load().await.unwrap(), LoadStatus::Ready));
			assert_eq!(session.state().unwrap().revision().unwrap(), 1);
			let repeated = session
				.mutate(text("change"), 999, &material, Impact::Realization, |_| {
					panic!("retry must not apply twice")
				})
				.await
				.unwrap();
			assert_eq!(repeated, (1, None));
			assert_eq!(view.read(|s| s.revision()).unwrap().unwrap(), 1);
			drop(session);
			assert!(view.read(|s| s.revision()).is_err());
		});
}
