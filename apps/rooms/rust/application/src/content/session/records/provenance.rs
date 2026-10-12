//! One private data family retains sender and bridge origins beyond receipts.
//! Both families refer to typed custody. Workspace exports contain neither.
use super::{Custody, Error, References, pages};
use crate::{content::session, fields::List};
use alloc::vec::Vec;
use serde::{Deserialize, Serialize};

pub type Origins = List<session::outgoing::Origin, { session::custody::MAX_FIELDS_PER_ROLE }>;
pub type Bridges = List<session::bridge::Witness, { session::bridge::MAX_WITNESSES }>;
/// Both empty arrays and their member names when the private family is first
/// allocated. Reservation proofs hold this envelope against the serde encoder.
pub const EMPTY_BYTES: usize = b"{\"outgoing\":[],\"bridges\":[]}".len();

#[derive(Serialize)]
struct Borrowed<'a> {
	outgoing: &'a Origins,
	bridges: &'a Bridges,
}
#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct Private {
	pub outgoing: Origins,
	pub bridges: Bridges,
}
pub fn encode(outgoing: &Origins, bridges: &Bridges) -> Result<Vec<Vec<u8>>, Error> {
	if outgoing.is_empty() && bridges.is_empty() {
		return Ok(Vec::new());
	}
	pages::encode(
		super::PROVENANCE.id,
		&serde_json::to_vec(&Borrowed { outgoing, bridges })?,
	)
}
pub fn decode(payloads: &[&[u8]]) -> Result<Private, Error> {
	if payloads.is_empty() {
		return Ok(Private::default());
	}
	let bytes = pages::decode(super::PROVENANCE.id, payloads)?;
	Ok(serde_json::from_slice(&bytes)?)
}
pub fn check_bridges<R: References>(bridges: &Bridges, held: &Custody<R>) -> Result<(), Error> {
	for (at, witness) in bridges.as_slice().iter().enumerate() {
		if !witness.validate(held)
			|| bridges.as_slice()[..at]
				.iter()
				.any(|other| other.id == witness.id || other.operation == witness.operation)
		{
			return Err(Error::Fields);
		}
	}
	Ok(())
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn initial_private_family_reserves_its_complete_encoded_envelope() {
		let outgoing = Origins::default();
		let bridges = Bridges::default();
		assert_eq!(
			serde_json::to_vec(&Borrowed {
				outgoing: &outgoing,
				bridges: &bridges
			})
			.unwrap()
			.len(),
			EMPTY_BYTES
		);
	}
}
