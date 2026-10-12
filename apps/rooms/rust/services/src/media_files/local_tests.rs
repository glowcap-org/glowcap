use super::*;
use crate::archive::Chunk;
use rooms_application::files::CHUNK_BYTES;
use rooms_application::files::FileDescription;
use rooms_glowcap::client::sources::{Reader, Source};
use std::{future::Future, pin::Pin};
fn description(size: usize) -> FileDescription {
	FileDescription::new("local".into(), "application/octet-stream".into(), size as u64, 0, 0).unwrap()
}
struct Invalid;
impl Reader for Invalid {
	fn read(&self, _: usize, _: usize) -> Pin<Box<dyn Future<Output = Result<Vec<u8>, String>>>> {
		Box::pin(async { Ok(Vec::new()) })
	}
}
struct Timeout;
impl rooms_glowcap::client::Deadline for Timeout {
	fn monotonic_millis(&self) -> u64 {
		0
	}
	async fn within<T>(&self, _: u64, _: impl Future<Output = T>) -> Option<T> {
		None
	}
}
#[tokio::test]
async fn local_bytes_share_storage_but_executor_handoffs_retain_only_bounded_allocations() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let size = CHUNK_BYTES * 3;
			let bytes = vec![7; size];
			let original = bytes.as_ptr();
			let source = Source::bytes(description(size), bytes).unwrap();
			let copy = source.clone();
			let mut owner = MediaFiles::default();
			let file = owner.retain_sources(vec![source], &[]).unwrap().pop().unwrap();
			let capture = file.materialize().await.unwrap();
			let span = capture.span(0, CHUNK_BYTES).unwrap();
			assert_eq!(span.as_ref().as_ptr(), original, "no full file copy on local capture");
			assert_eq!(
				copy.read(&HostPlatform, 0, CHUNK_BYTES)
					.await
					.unwrap()
					.as_ref()
					.as_ptr(),
				original
			);
			let disk = span.into_bounded(CHUNK_BYTES).unwrap();
			assert_ne!(
				disk.as_ref().as_ptr(),
				original,
				"disk jobs must not retain the large source allocation"
			);
			assert_eq!(disk.as_ref(), vec![7; CHUNK_BYTES]);
			let small = std::sync::Arc::new(vec![8; CHUNK_BYTES].into_boxed_slice());
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
			assert!(copy.read(&HostPlatform, 0, 0).await.is_err());
			assert!(copy.read(&HostPlatform, u64::MAX, 1).await.unwrap().as_ref().is_empty());
			owner.close().await.unwrap();
			assert!(file.read(0, 1).await.is_err());
			assert_eq!(capture.read(0, 3).unwrap(), [7; 3]);
			assert_eq!(
				owner.usage().bytes,
				size,
				"admitted capture remains charged after owner shutdown"
			);
			drop(capture);
			assert_eq!(owner.usage().bytes, 0);
		})
		.await;
}
#[tokio::test]
async fn local_reader_length_and_deadline_fail_before_materialization() {
	let source = Source::reader(description(1), Invalid);
	assert!(
		source
			.materialize(&HostPlatform)
			.await
			.err()
			.unwrap()
			.contains("invalid span")
	);
	assert!(
		source
			.materialize(&Timeout)
			.await
			.err()
			.unwrap()
			.contains("stopped answering")
	);
}
