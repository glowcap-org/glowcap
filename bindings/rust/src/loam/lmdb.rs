//! The LMDB storage engine for a Rust Store.
use super::archive::{self, Archive, OpenMode};
use super::{Engine, Executor, executor::sealed, ffi};
use crate::Result;
use std::{path::PathBuf, sync::Arc};

/// The LMDB engine. `map_bytes` is the database file-size limit, at least 1 MiB,
/// independent of the resident and staged record bytes in `Limits`.
#[derive(Clone, Debug)]
pub struct Lmdb {
	pub path: PathBuf,
	pub identity: [u8; 16],
	pub mode: OpenMode,
	pub map_bytes: usize,
}

impl Engine for Lmdb {}

impl sealed::Open for Lmdb {
	fn open(
		self,
		schemas: &[ffi::GlowcapLoamSchema],
		limits: &ffi::GlowcapLoamLimits,
	) -> Result<(Arc<dyn Executor>, *mut ffi::GlowcapLoamStore)> {
		archive::open_disk(
			&ARCHIVE,
			ffi::glowcap_loam_lmdb_open,
			&self.path,
			&self.identity,
			self.mode,
			self.map_bytes,
			schemas,
			limits,
		)
	}
}

static ARCHIVE: Archive<ffi::GlowcapLoamLmdb> = Archive {
	fingerprint: ffi::glowcap_loam_lmdb_archive_fingerprint,
	expected: ffi::LOAM_LMDB_ARCHIVE_FINGERPRINT,
	work_run: ffi::glowcap_loam_lmdb_work_run,
	restore: ffi::glowcap_loam_lmdb_restore,
	commit: ffi::glowcap_loam_lmdb_commit,
	collect: ffi::glowcap_loam_lmdb_collect,
	recover: ffi::glowcap_loam_lmdb_recover,
	release: ffi::glowcap_loam_lmdb_release,
	last_error: ffi::glowcap_loam_lmdb_last_error,
};
