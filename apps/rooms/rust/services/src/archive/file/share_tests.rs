use super::{tests::Temp, *};
use rooms_application::archive::shares::{self, ApplyError, Change, Command, Share};
use std::{fs, io, time::Duration};
const ID: &str = "12345678-1234-4234-8234-123456789abc";
fn share() -> Share {
	Share::new(
		ID.into(),
		"garden".into(),
		Filter {
			directory: Some("directory".into()),
			..Default::default()
		},
	)
	.unwrap()
}
#[tokio::test]
async fn share_identity_and_revocation_survive_restart_under_archive_custody() {
	let temp = Temp::new();
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	assert!(archive.active_shares().await.unwrap().is_empty());
	assert_eq!(
		archive.change_share(Command::Issue(share())).await.unwrap(),
		Change::Issued
	);
	let before = fs::read(temp.0.join(shares::FILE)).unwrap();
	assert_eq!(
		archive.change_share(Command::Issue(share())).await.unwrap(),
		Change::Unchanged
	);
	assert_eq!(fs::read(temp.0.join(shares::FILE)).unwrap(), before);
	assert!(FileArchive::open(&temp.0, Options::default()).await.is_err());
	drop(archive);
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	assert_eq!(archive.active_shares().await.unwrap(), vec![share()]);
	assert_eq!(
		archive.change_share(Command::Revoke(ID.into())).await.unwrap(),
		Change::Revoked
	);
	drop(archive);
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	assert!(archive.active_shares().await.unwrap().is_empty());
	assert!(archive.change_share(Command::Issue(share())).await.is_err());
	drop(archive);
	fs::write(temp.0.join(shares::FILE), b"{broken").unwrap();
	assert!(FileArchive::open(&temp.0, Options::default()).await.is_err());
	assert_eq!(fs::read(temp.0.join(shares::FILE)).unwrap(), b"{broken");
}
#[tokio::test]
async fn cancelled_share_observation_drains_before_another_admission() {
	let temp = Temp::new();
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	let store = archive.store.clone();
	let (held, ready) = std::sync::mpsc::channel();
	let (release, wait) = std::sync::mpsc::channel();
	let lock = std::thread::spawn(move || {
		let _guard = store.lock().unwrap();
		held.send(()).unwrap();
		wait.recv().unwrap();
	});
	ready.recv().unwrap();
	assert!(
		tokio::time::timeout(Duration::from_millis(20), archive.change_share(Command::Issue(share())))
			.await
			.is_err()
	);
	assert!(archive.pending.is_some());
	release.send(()).unwrap();
	lock.join().unwrap();
	archive.finish_pending().await.unwrap();
	assert_eq!(archive.active_shares().await.unwrap(), vec![share()]);
}
#[test]
fn uncertain_share_rename_requires_recovery_and_restores_the_actual_revocation() {
	let temp = Temp::new();
	let mut store = Store::open(temp.0.clone(), Options::default()).unwrap();
	store
		.shares
		.apply(Command::Issue(share()), |bytes| {
			storage::atomic::replace(&store.directory, shares::FILE, [bytes])
		})
		.unwrap();
	let outcome = store.shares.apply(Command::Revoke(ID.into()), |bytes| {
		storage::atomic::replace_with_sync(&store.directory, shares::FILE, [bytes], || {
			Err(io::Error::other("injected final directory sync failure"))
		})
	});
	let Err(ApplyError::Storage(failure)) = outcome else {
		panic!("must retain indeterminate outcome")
	};
	assert!(store.written(Err(failure)).is_err());
	assert!(store.live().is_err());
	assert!(store.shares.records().is_err());
	drop(store);
	let store = Store::open(temp.0.clone(), Options::default()).unwrap();
	assert!(store.shares.get(ID).unwrap().unwrap().revoked());
}
