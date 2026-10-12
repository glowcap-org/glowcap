//! Identity of immutable attachment content. Metadata alone cannot distinguish
//! two uploads with the same name and length. Adapters hash the bytes they send.
use super::FileDescription;
use serde::{Serialize, Serializer};

pub struct Identity<'a> {
	pub description: &'a FileDescription,
	pub digest: [u8; 32],
}
impl Serialize for Identity<'_> {
	fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
		let d = self.description;
		(
			d.name(),
			d.mime(),
			d.size(),
			d.dimensions().0,
			d.dimensions().1,
			self.digest,
		)
			.serialize(serializer)
	}
}
