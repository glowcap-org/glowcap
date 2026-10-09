//! Whole-account reads use the application merge contract and preserve which
//! held reader supplied each winning record. Cross-archive revisions never mix.
use super::*;
use rooms_application::archive::merge::{self, Account, Limits};

pub struct KeptRecord {
	pub record: Arc<Record>,
	/// Zero names the first reader, one the second; callers retain both readers.
	pub keeper: u8,
}
impl<D: Deadline> Archive<D> {
	/// The scan charges every row, including duplicates. Merge borrows shared
	/// records and copies only the winning Arc and fixed keeper index into the
	/// returned spine; file bytes stay at the exact supplying archive.
	pub async fn read_together(&self, device: &Self, filter: &Filter) -> Result<Vec<KeptRecord>, Error> {
		let peer = self.read_all(filter).await?;
		let local = device.read_all(filter).await?;
		let records = merge::merge(
			&[
				Account {
					keeper: &0u8,
					writes: true,
					records: &peer,
				},
				Account {
					keeper: &1u8,
					writes: false,
					records: &local,
				},
			],
			Limits {
				accounts: 2,
				records: 2 * archive::MAX_RECORDS,
			},
		)?;
		Ok(records
			.into_iter()
			.map(|row| KeptRecord {
				record: row.record.clone(),
				keeper: *row.keeper,
			})
			.collect())
	}
}
