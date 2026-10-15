//! The disk engines a storage proof runs on. Rooms stores sessions in SQLite,
//! and each proof that reopens a store also runs on LMDB, so Rooms' data model
//! keeps exercising both engines behind the one Loam contract.
use glowcap::{
	Result,
	loam::{Limits, OpenMode, Schema, Store},
};
use std::path::PathBuf;

/// The physical bytes a proof store may hold, well above any proof's data.
const BYTES: usize = 256 * 1024 * 1024;

#[derive(Clone, Copy, Debug)]
pub(crate) enum Disk {
	Sqlite,
	Lmdb,
}
impl Disk {
	pub(crate) fn open(
		self,
		path: PathBuf,
		identity: [u8; 16],
		mode: OpenMode,
		schemas: &[Schema],
		limits: Limits,
	) -> Result<Store> {
		match self {
			Self::Sqlite => Store::open(
				glowcap::loam::Sqlite {
					path,
					identity,
					mode,
					capacity_bytes: BYTES,
				},
				schemas,
				limits,
			),
			Self::Lmdb => Store::open(
				glowcap::loam::Lmdb {
					path,
					identity,
					mode,
					map_bytes: BYTES,
				},
				schemas,
				limits,
			),
		}
	}
}
