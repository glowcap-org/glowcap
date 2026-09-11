use super::*;
use rooms_application::documents::{DocumentError, WriteFailure};
use rooms_application::grants::{Command, Error as GrantError, Rights};
use std::{
	fs::{self, File},
	future::Future,
	io,
	path::PathBuf,
	sync::{
		atomic::{AtomicU64, Ordering},
		mpsc,
	},
	task::{Context, Poll, Waker},
};

static NEXT: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
	fn new() -> Self {
		let path = std::env::temp_dir().join(format!(
			"rooms-documents-test-{}-{}",
			std::process::id(),
			NEXT.fetch_add(1, Ordering::Relaxed)
		));
		fs::create_dir(&path).unwrap();
		Self(path)
	}
	fn state(&self) -> PathBuf {
		self.0.join("state")
	}
}
impl Drop for Temp {
	fn drop(&mut self) {
		fs::remove_dir_all(&self.0).unwrap();
	}
}

fn issue() -> Command {
	Command::Issue {
		id: "00000000-0000-4000-8000-000000000001".into(),
		rights: Rights::Interact,
		label: "phone".into(),
		history: false,
	}
}

#[tokio::test]
async fn documents_preserve_paths_limits_secrets_and_exclusive_ownership() {
	let temp = Temp::new();
	let mut docs = SessionDocuments::open(temp.state()).await.unwrap();
	assert!(SessionDocuments::open(temp.state()).await.is_err());
	assert_eq!(docs.checkpoint.read().await.unwrap(), None);
	assert_eq!(docs.effects.read().await.unwrap(), None);
	let checkpoint = br#"{"version":1,"checkpoint":{}}"#.to_vec();
	docs.checkpoint.replace(checkpoint.clone()).await.unwrap();
	docs.bridge_secrets
		.replace(br#"{"secret":"fixture credential"}"#.to_vec())
		.await
		.unwrap();
	assert_eq!(fs::read(temp.state().join("session.json")).unwrap(), checkpoint);
	assert_eq!(docs.checkpoint.read().await.unwrap(), Some(checkpoint));
	assert!(!fs::read_to_string(temp.state().join("session.json"))
		.unwrap()
		.contains("credential"));
	let previous = fs::read(temp.state().join("session.json")).unwrap();
	assert!(matches!(
		docs.checkpoint
			.replace(vec![b'x'; SessionDocument::Checkpoint.max_bytes() + 1])
			.await,
		Err(WriteFailure::Unchanged(StorageError::Document(DocumentError::TooLarge)))
	));
	assert!(matches!(
		docs.checkpoint.replace(vec![255]).await,
		Err(WriteFailure::Unchanged(StorageError::Document(DocumentError::Utf8)))
	));
	assert_eq!(fs::read(temp.state().join("session.json")).unwrap(), previous);
	fs::write(temp.state().join("effects.json"), b"\xef\xbb\xbf{}\n").unwrap();
	assert_eq!(docs.effects.read().await.unwrap(), Some(b"{}\n".to_vec()));
	fs::write(temp.state().join("effects.json"), [255]).unwrap();
	assert!(matches!(
		docs.effects.read().await,
		Err(StorageError::Document(DocumentError::Utf8))
	));
	let file = File::create(temp.state().join("effects.json")).unwrap();
	file.set_len(SessionDocument::Effects.max_bytes() as u64 + 1).unwrap();
	drop(file);
	assert!(matches!(
		docs.effects.read().await,
		Err(StorageError::Document(DocumentError::TooLarge))
	));
	#[cfg(unix)]
	{
		use std::os::unix::fs::PermissionsExt;
		assert_eq!(fs::metadata(temp.state()).unwrap().permissions().mode() & 0o777, 0o700);
		assert_eq!(
			fs::metadata(temp.state().join("bridge-secrets.json"))
				.unwrap()
				.permissions()
				.mode() & 0o777,
			0o600
		);
	}
	drop(docs);
	let reopened = SessionDocuments::open(temp.state()).await.unwrap();
	drop(reopened);
}

#[tokio::test]
async fn file_grants_preserve_the_existing_two_decode_boundaries() {
	let temp = Temp::new();
	let mut docs = SessionDocuments::open(temp.state()).await.unwrap();
	let mut grants = docs.take_grants().unwrap();
	for count in 0..=3 {
		let mut bytes = b"\xef\xbb\xbf".repeat(count);
		bytes.extend_from_slice(include_bytes!("../../../proofs/fixtures/grants-v1.json"));
		fs::write(temp.state().join("grants.json"), &bytes).unwrap();
		assert_eq!(grants.load().await.is_ok(), count <= 2);
		assert_eq!(fs::read(temp.state().join("grants.json")).unwrap(), bytes);
	}
	assert!(matches!(grants.ledger(), Err(GrantError::RecoveryRequired)));
}

#[tokio::test]
async fn persisted_grants_restore_current_fixtures_and_refuse_corrupt_recovery() {
	let temp = Temp::new();
	let mut docs = SessionDocuments::open(temp.state()).await.unwrap();
	fs::write(
		temp.state().join("grants.json"),
		include_bytes!("../../../proofs/fixtures/grants-surrogate-v1.json"),
	)
	.unwrap();
	let mut grants = docs.take_grants().unwrap();
	assert!(docs.take_grants().is_none());
	assert!(matches!(grants.ledger(), Err(GrantError::RecoveryRequired)));
	grants.load().await.unwrap();
	grants
		.apply(Command::Revoke {
			id: "00000000-0000-4000-8000-000000000001".into(),
		})
		.await
		.unwrap();
	let before = grants.ledger().unwrap().document().unwrap();
	drop(grants);
	drop(docs);
	let mut docs = SessionDocuments::open(temp.state()).await.unwrap();
	let mut grants = docs.take_grants().unwrap();
	grants.load().await.unwrap();
	assert_eq!(grants.ledger().unwrap().document().unwrap(), before);
	assert!(grants
		.ledger()
		.unwrap()
		.get("00000000-0000-4000-8000-000000000001")
		.unwrap()
		.unwrap()
		.revoked());
	fs::write(temp.state().join("grants.json"), b"not JSON").unwrap();
	assert!(grants.load().await.is_err());
	assert!(matches!(grants.ledger(), Err(GrantError::RecoveryRequired)));
	assert_eq!(fs::read(temp.state().join("grants.json")).unwrap(), b"not JSON");
	fs::remove_file(temp.state().join("grants.json")).unwrap();
	assert!(matches!(grants.load().await, Err(crate::grants::LoadError::Missing)));
	assert!(!temp.state().join("grants.json").exists());
}

#[tokio::test]
async fn a_failure_before_staging_preserves_the_live_grant_policy() {
	let temp = Temp::new();
	let mut docs = SessionDocuments::open(temp.state()).await.unwrap();
	let mut grants = docs.take_grants().unwrap();
	grants.load().await.unwrap();
	let moved = temp.0.join("moved");
	fs::rename(temp.state(), &moved).unwrap();
	assert!(matches!(
		grants.apply(issue()).await,
		Err(rooms_application::grants::ApplyError::Storage(WriteFailure::Unchanged(
			_
		)))
	));
	assert_eq!(grants.ledger().unwrap().active_count().unwrap(), 0);
	fs::rename(&moved, temp.state()).unwrap();
	grants.apply(issue()).await.unwrap();
	assert_eq!(grants.ledger().unwrap().active_count().unwrap(), 1);
}

#[test]
fn an_error_after_replacement_never_claims_the_old_document_survived() {
	let temp = Temp::new();
	let directory = Directory::open(temp.state(), ".rooms-session.lock").unwrap();
	fs::write(temp.state().join("grants.json"), b"old").unwrap();
	let result = atomic::replace_with_sync(&directory, SessionDocument::Grants, b"new", || {
		Err(io::Error::other("injected directory sync refusal"))
	});
	assert!(matches!(result, Err(WriteFailure::Indeterminate(_))));
	assert_eq!(fs::read(temp.state().join("grants.json")).unwrap(), b"new");
	assert_eq!(fs::read_dir(temp.state()).unwrap().count(), 2); // document and lease
	fs::remove_file(temp.state().join("grants.json")).unwrap();
	fs::create_dir(temp.state().join("grants.json")).unwrap();
	assert!(matches!(
		atomic::replace(&directory, SessionDocument::Grants, b"new"),
		Err(WriteFailure::Indeterminate(_))
	));
	assert_eq!(fs::read_dir(temp.state()).unwrap().count(), 2);
}

// Occupy the only blocking worker. Cancelling the observer then occurs after
// the real write is queued but before it can run, without timing assumptions.
async fn block_worker() -> (mpsc::Sender<()>, JoinHandle<()>) {
	let (release, wait) = mpsc::channel();
	let (started, ready) = tokio::sync::oneshot::channel();
	let task = tokio::task::spawn_blocking(move || {
		started.send(()).unwrap();
		let _ = wait.recv();
	});
	ready.await.unwrap();
	(release, task)
}

#[test]
fn cancelled_grant_writes_must_finish_before_reload() {
	tokio::runtime::Builder::new_current_thread()
		.max_blocking_threads(1)
		.build()
		.unwrap()
		.block_on(async {
			let temp = Temp::new();
			let mut docs = SessionDocuments::open(temp.state()).await.unwrap();
			let mut grants = docs.take_grants().unwrap();
			grants.load().await.unwrap();
			grants.apply(issue()).await.unwrap();
			let policy = grants.policy("00000000-0000-4000-8000-000000000001").unwrap();
			let (release, blocker) = block_worker().await;
			let mut apply = Box::pin(grants.apply(Command::Revoke {
				id: "00000000-0000-4000-8000-000000000001".into(),
			}));
			assert!(matches!(
				apply.as_mut().poll(&mut Context::from_waker(Waker::noop())),
				Poll::Pending
			));
			assert_eq!(
				policy.read(|g| g.access()).unwrap(),
				rooms_application::grants::Access::Interact
			);
			drop(apply);
			assert_eq!(policy.read(|g| g.access()), Err(GrantError::RecoveryRequired));
			assert!(matches!(grants.ledger(), Err(GrantError::RecoveryRequired)));
			assert!(matches!(grants.load().await, Err(crate::grants::LoadError::Pending)));
			let mut recovery = Box::pin(grants.finish_pending());
			assert!(matches!(
				recovery.as_mut().poll(&mut Context::from_waker(Waker::noop())),
				Poll::Pending
			));
			drop(recovery);
			release.send(()).unwrap();
			blocker.await.unwrap();
			assert!(matches!(grants.finish_pending().await, Some(Completion::Write(Ok(())))));
			grants.load().await.unwrap();
			assert_eq!(grants.ledger().unwrap().active_count().unwrap(), 0);
			assert_eq!(policy.read(|g| g.access()), Err(GrantError::Revoked));
			assert!(grants.finish_pending().await.is_none());
		});
}

#[test]
fn dropping_an_owner_keeps_the_directory_locked_until_its_worker_stops() {
	tokio::runtime::Builder::new_current_thread()
		.max_blocking_threads(1)
		.build()
		.unwrap()
		.block_on(async {
			let temp = Temp::new();
			let mut docs = SessionDocuments::open(temp.state()).await.unwrap();
			let (release, blocker) = block_worker().await;
			let mut write = Box::pin(docs.checkpoint.replace(b"{}".to_vec()));
			assert!(write
				.as_mut()
				.poll(&mut Context::from_waker(Waker::noop()))
				.is_pending());
			drop(write);
			assert!(matches!(docs.checkpoint.read().await, Err(StorageError::Pending)));
			drop(docs);
			assert!(Directory::open(temp.state(), ".rooms-session.lock").is_err());
			release.send(()).unwrap();
			blocker.await.unwrap();
			// FIFO blocking work: reopening cannot run before the queued writer.
			let mut reopened = SessionDocuments::open(temp.state()).await.unwrap();
			assert_eq!(reopened.checkpoint.read().await.unwrap(), Some(b"{}".to_vec()));
		});
}

/// A staging file left by an incarnation that died mid-replacement is debris
/// the next open sweeps; the documents beside it are untouched.
#[tokio::test]
async fn opening_sweeps_staging_files_a_dead_incarnation_left() {
	let temp = Temp::new();
	fs::create_dir(temp.state()).unwrap();
	fs::write(temp.state().join(".session.json.tmp-4242-7"), b"{").unwrap();
	fs::write(temp.state().join("session.json"), b"{}").unwrap();
	let mut docs = SessionDocuments::open(temp.state()).await.unwrap();
	assert!(!temp.state().join(".session.json.tmp-4242-7").exists());
	assert_eq!(docs.checkpoint.read().await.unwrap(), Some(b"{}".to_vec()));
}
