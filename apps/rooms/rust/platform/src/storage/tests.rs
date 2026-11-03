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
