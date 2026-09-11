//! Durable verbs require explicit issuer authority at the hosting boundary.
use super::{Error, Share};
use crate::{archive::protocol, room::ListArgument};
use alloc::string::String;
pub const ISSUE: &str = "share";
pub const REVOKE: &str = "revokeShare";
pub const LIST: &str = "shares";
pub enum Request {
	Issue(Share),
	Revoke(String),
	List,
}
impl Request {
	pub fn read<A: ListArgument>(verb: &str, args: &[A]) -> Result<Self, Error> {
		match (verb, args) {
			(LIST, []) => Ok(Self::List),
			(REVOKE, [id]) => {
				let id = id.text().ok_or(Error::Invalid)?;
				// Unknown IDs remain an idempotent false; bound retained input.
				if id.len() > 128 {
					return Err(Error::Invalid);
				}
				Ok(Self::Revoke(id.into()))
			}
			(ISSUE, [id, label, filter]) => {
				let id = id.text().ok_or(Error::Invalid)?;
				let label = label.text().ok_or(Error::Invalid)?;
				crate::grants::validate_id(id).map_err(|_| Error::Invalid)?;
				crate::grants::validate_label(label.encode_utf16()).map_err(|_| Error::Invalid)?;
				Share::new(
					id.into(),
					label.into(),
					protocol::filter(filter).map_err(|_| Error::Invalid)?,
				)
				.map(Self::Issue)
			}
			_ => Err(Error::Invalid),
		}
	}
	pub fn heap_bytes(&self) -> usize {
		match self {
			Self::Issue(share) => share.id.capacity() + share.label.heap_bytes() + share.filter.retained_bytes(),
			Self::Revoke(id) => id.capacity(),
			Self::List => 0,
		}
	}
}

/// The three immutable issuance fields also prefix each listed share.
pub fn issue<O: crate::archive::output::Output>(share: &Share) -> Result<alloc::vec::Vec<O::Value>, Error> {
	share.validate()?;
	Ok(alloc::vec![
		O::text(share.id()),
		O::document(share.label()),
		crate::archive::output::filter::<O>(share.filter()).map_err(|_| Error::Invalid)?
	])
}
pub fn row<O: crate::archive::output::Output>(share: &Share, link: &str) -> Result<O::Value, Error> {
	let mut row = issue::<O>(share)?;
	row.push(O::text(link));
	Ok(O::list(row))
}
