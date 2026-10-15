//! The SQLite storage engine for a Rust Store.
use super::archive::{self, Archive, OpenMode};
use super::{Engine, Executor, executor::sealed, ffi};
use crate::Result;
use std::{path::PathBuf, sync::Arc};

/// The SQLite engine. `capacity_bytes` is the largest the database file may
/// grow, at least 1 MiB, independent of the resident and staged record bytes
/// in `Limits`.
#[derive(Clone, Debug)]
pub struct Sqlite {
	pub path: PathBuf,
	pub identity: [u8; 16],
	pub mode: OpenMode,
	pub capacity_bytes: usize,
}

impl Engine for Sqlite {}

impl sealed::Open for Sqlite {
	fn open(
		self,
		schemas: &[ffi::GlowcapLoamSchema],
		limits: &ffi::GlowcapLoamLimits,
	) -> Result<(Arc<dyn Executor>, *mut ffi::GlowcapLoamStore)> {
		archive::open_disk(
			&ARCHIVE,
			ffi::glowcap_loam_sqlite_open,
			&self.path,
			&self.identity,
			self.mode,
			self.capacity_bytes,
			schemas,
			limits,
		)
	}
}

static ARCHIVE: Archive<ffi::GlowcapLoamSqlite> = Archive {
	fingerprint: ffi::glowcap_loam_sqlite_archive_fingerprint,
	expected: ffi::LOAM_SQLITE_ARCHIVE_FINGERPRINT,
	work_run: ffi::glowcap_loam_sqlite_work_run,
	restore: ffi::glowcap_loam_sqlite_restore,
	commit: ffi::glowcap_loam_sqlite_commit,
	collect: ffi::glowcap_loam_sqlite_collect,
	recover: ffi::glowcap_loam_sqlite_recover,
	release: ffi::glowcap_loam_sqlite_release,
	last_error: ffi::glowcap_loam_sqlite_last_error,
};
