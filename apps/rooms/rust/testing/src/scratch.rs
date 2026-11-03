//! A scratch directory that a test owns and the guard removes. Its path is
//! `rooms-<label>-<process id>-<nonce>` under the system temporary directory,
//! so a directory that outlives its test still names the test that leaked it.
//!
//! The guard removes the tree when it drops. A removal that fails fails the
//! test, because a leaked directory is the defect the guard exists to catch.
//! While the thread is already panicking the failure is dropped instead: a
//! second panic during unwinding aborts the process and hides the first.

use std::{
	fs, io,
	ops::Deref,
	path::{Path, PathBuf},
	sync::atomic::{AtomicU64, Ordering},
	time::{SystemTime, UNIX_EPOCH},
};

static NEXT: AtomicU64 = AtomicU64::new(0);

/// A directory path the test may create, fill, and expect to vanish with it.
pub struct Scratch {
	path: PathBuf,
}

impl Scratch {
	/// Name a directory for `label` without creating it. The code under test
	/// creates it, or the test does.
	pub fn new(label: &str) -> Self {
		let nanos = SystemTime::now()
			.duration_since(UNIX_EPOCH)
			.map_or(0, |elapsed| elapsed.subsec_nanos());
		let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
		let path = std::env::temp_dir().join(format!("rooms-{label}-{}-{nanos:08x}{sequence:x}", std::process::id()));
		Self { path }
	}

	/// Name a directory for `label` and create it empty. A directory that
	/// already exists under the name is a stale leak, and refuses the test.
	pub fn create(label: &str) -> Self {
		let scratch = Self::new(label);
		if let Err(error) = fs::create_dir(&scratch.path) {
			panic!("create scratch directory {}: {error}", scratch.path.display());
		}
		scratch
	}
}

impl Deref for Scratch {
	type Target = Path;

	fn deref(&self) -> &Path {
		&self.path
	}
}

impl AsRef<Path> for Scratch {
	fn as_ref(&self) -> &Path {
		&self.path
	}
}

impl Drop for Scratch {
	fn drop(&mut self) {
		match fs::remove_dir_all(&self.path) {
			Ok(()) => {}
			// A test that never created the directory has nothing to leak.
			Err(error) if error.kind() == io::ErrorKind::NotFound => {}
			Err(error) => {
				// A panic here during unwinding would abort the process and hide
				// the failure that started the unwinding; that failure is the
				// one the test must report.
				if !std::thread::panicking() {
					panic!("remove scratch directory {}: {error}", self.path.display());
				}
			}
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn the_path_names_the_label_and_the_process_and_the_guard_removes_the_tree() {
		let scratch = Scratch::create("scratch-guard");
		let name = scratch.file_name().unwrap().to_str().unwrap().to_owned();
		assert!(
			name.starts_with(&format!("rooms-scratch-guard-{}-", std::process::id())),
			"{name}"
		);
		fs::write(scratch.join("kept"), b"x").unwrap();
		let path = scratch.to_path_buf();
		drop(scratch);
		assert!(!path.exists());
	}

	#[test]
	fn two_guards_with_one_label_name_different_directories() {
		let (first, second) = (Scratch::new("twice"), Scratch::new("twice"));
		assert_ne!(*first, *second);
	}

	#[test]
	fn a_directory_that_was_never_created_is_not_a_leak() {
		drop(Scratch::new("never-created"));
	}

	#[test]
	#[should_panic(expected = "remove scratch directory")]
	fn a_removal_that_fails_fails_the_test() {
		let scratch = Scratch::new("leaked");
		// A file under the name cannot be removed as a directory tree.
		fs::write(&*scratch, b"not a directory").unwrap();
		let leaked = scratch.to_path_buf();
		let guard = scratch;
		// Remove the file after the guard fails, so the test leaks nothing.
		struct Cleanup(PathBuf);
		impl Drop for Cleanup {
			fn drop(&mut self) {
				let _ = fs::remove_file(&self.0); // best-effort: test cleanup
			}
		}
		let _cleanup = Cleanup(leaked);
		drop(guard);
	}

	#[test]
	fn a_removal_that_fails_while_panicking_leaves_the_first_panic_intact() {
		let scratch = Scratch::new("leaked-while-panicking");
		fs::write(&*scratch, b"not a directory").unwrap();
		let path = scratch.to_path_buf();
		let outcome = std::panic::catch_unwind(move || {
			let _guard = scratch;
			panic!("the first failure");
		});
		fs::remove_file(path).unwrap();
		let payload = outcome.unwrap_err();
		assert_eq!(payload.downcast_ref::<&str>(), Some(&"the first failure"));
	}
}
