//! Admission for record storage and live facet methods. The host executes the
//! returned operation. Parsing itself cannot touch storage or mint authority.
use super::{Access, Error, Facet, Filter, Record, index::Page, protocol, records::safe};
use crate::{files::FileArgument, room::ListArgument};
use alloc::vec::Vec;

pub enum Request {
	Put(Record),
	Read { filter: Filter, after: u64, limit: usize },
	Empty(Page),
	Narrow(Facet),
}
impl Facet {
	pub fn admit<A: ListArgument + FileArgument>(&self, verb: &str, args: &[A]) -> Result<Request, Error> {
		match (verb, args) {
			(protocol::PUT, [row]) => {
				if self.access() != Access::ReadWrite {
					return Err(Error::Access);
				}
				let record = protocol::record(row)?;
				if !self.permits_put(&record) {
					return Err(Error::Filter);
				}
				Ok(Request::Put(record))
			}
			(protocol::READ, [filter, after, limit]) => {
				let filter = protocol::filter(filter)?;
				let after = u64::try_from(after.integer().ok_or(Error::Revision)?).map_err(|_| Error::Revision)?;
				safe(after, false)?;
				let limit = protocol::read_limit(limit)?;
				Ok(match self.scope().intersect(&filter) {
					Some(filter) => Request::Read { filter, after, limit },
					None => Request::Empty(Page {
						next: after,
						more: false,
						records: Vec::new(),
					}),
				})
			}
			(protocol::NARROW, [filter, access]) => {
				let filter = protocol::filter(filter)?;
				let access = match access.text() {
					Some("read") => Access::Read,
					Some("read-write") => Access::ReadWrite,
					_ => return Err(Error::Access),
				};
				Ok(Request::Narrow(self.narrow(&filter, access)?))
			}
			_ => Err(Error::Method),
		}
	}
}
impl Request {
	/// Owned input charge. The host owner separately charges queue and reply
	/// slots. Reply pages are produced serially, bounded by MAX_READ and records.
	pub fn heap_bytes(&self) -> usize {
		match self {
			Self::Put(record) => record.retained_bytes() - core::mem::size_of::<Record>(),
			Self::Read { filter, .. } => filter.retained_bytes(),
			Self::Narrow(facet) => facet.scope().retained_bytes(),
			Self::Empty(_) => 0,
		}
	}
}
/// Issuance work is nonrefundable for the lifetime of one caller session, even
/// when every returned occurrence has been released.
pub const MAX_FACETS_PER_SESSION: usize = 256;
pub struct MintBudget<const MAX: usize>(usize);
pub type Issuance = MintBudget<MAX_FACETS_PER_SESSION>;
impl<const MAX: usize> Default for MintBudget<MAX> {
	fn default() -> Self {
		Self::new()
	}
}
impl<const MAX: usize> MintBudget<MAX> {
	pub const fn new() -> Self {
		Self(0)
	}
	pub fn available(&self) -> bool {
		self.0 < MAX
	}
	/// Called only after the host has successfully minted the returned facet.
	pub fn minted(&mut self) -> Result<(), Error> {
		if !self.available() {
			return Err(Error::Capacity);
		}
		self.0 += 1;
		Ok(())
	}
}
