use super::*;
mod bridge;
use std::{
	fs,
	path::PathBuf,
	sync::atomic::{AtomicU64, Ordering},
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
