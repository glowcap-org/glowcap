use crate::archive::Chunk;
use rooms_application::files::CHUNK_BYTES;
use std::sync::Arc;
#[test]
fn bounded_chunks_copy_only_when_they_would_retain_a_larger_allocation() {
	let large = Arc::new(vec![7; CHUNK_BYTES * 3].into_boxed_slice());
	let original = large.as_ptr();
	let disk = Chunk::shared(large, 0..CHUNK_BYTES)
		.unwrap()
		.into_bounded(CHUNK_BYTES)
		.unwrap();
	assert_ne!(
		disk.as_ref().as_ptr(),
		original,
		"disk jobs must not retain the large source allocation"
	);
	assert_eq!(disk.as_ref(), vec![7; CHUNK_BYTES]);
	let small = Arc::new(vec![8; CHUNK_BYTES].into_boxed_slice());
	let bounded = Chunk::shared(small.clone(), 0..3)
		.unwrap()
		.into_bounded(CHUNK_BYTES)
		.unwrap();
	assert_eq!(
		bounded.as_ref().as_ptr(),
		small.as_ptr(),
		"already bounded captures do not copy"
	);
	assert!(Chunk::shared(small, 0..CHUNK_BYTES).unwrap().into_bounded(1).is_err());
}
