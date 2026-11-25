use super::*;

#[test]
fn directory_release_does_not_wait_for_inherited_descriptors() {
	let scratch = rooms_testing::scratch::Scratch::new("directory-lease");
	let path = scratch.to_path_buf();
	let owner = std::sync::Arc::new(Directory::open(path.clone(), ".lock").unwrap());
	let worker = owner.clone();
	// A duplicate models the open-file description inherited between fork and
	// exec: closing the parent's descriptor alone cannot release its lock.
	let inherited = owner._lock.try_clone().unwrap();
	drop(owner);
	assert!(matches!(
		Directory::open(path.clone(), ".lock"),
		Err(StorageError::InUse(_))
	));
	drop(worker);
	let next = Directory::open(path.clone(), ".lock").unwrap();
	drop(inherited);
	assert!(matches!(
		Directory::open(path.clone(), ".lock"),
		Err(StorageError::InUse(_))
	));
	drop(next);
}

#[test]
fn readers_never_see_each_other_and_an_owner_waits_one_out_within_its_bound() {
	let scratch = rooms_testing::scratch::Scratch::new("directory-readers");
	let path = scratch.to_path_buf();
	drop(Directory::open(path.clone(), ".lock").unwrap());
	let first = Reading::begin(&path, ".lock").unwrap().expect("no owner holds it");
	let second = Reading::begin(&path, ".lock").unwrap().expect("a reader holds it");
	assert!(matches!(
		Directory::open(path.clone(), ".lock"),
		Err(StorageError::InUse(_))
	));
	// The readers go after `HELD`, while the owner is already waiting: the
	// call below starts with both held, so it cannot return before they go.
	// Nothing announces that a lock attempt is waiting, so the delay is the
	// only way to make the release come after it.
	const HELD: Duration = Duration::from_millis(100);
	// Taken before the thread starts, so the releaser's sleep cannot begin
	// before `began` and make the owner's wait shorter than `HELD`.
	let began = std::time::Instant::now();
	let releaser = std::thread::spawn(move || {
		std::thread::sleep(HELD);
		drop((first, second));
	});
	let owner = Directory::open_within(path, ".lock", Duration::from_millis(500));
	assert!(owner.is_ok(), "a reader was not waited out");
	assert!(began.elapsed() >= HELD, "the owner took the lock while readers held it");
	releaser.join().unwrap();
}
