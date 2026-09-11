//! Combined archive views preserve the winning record and its keeper (ADR-0144).
//! Identity belongs to the archive index; revisions from different accounts are
//! incomparable. Lifecycle wins first, then the current writer, then listed order.
use super::{
	index::{Entry, Identity},
	Body, Error, LineState, Record,
};
use alloc::{collections::BTreeMap, sync::Arc, vec::Vec};
pub struct Account<'a, K> {
	pub keeper: &'a K,
	pub writes: bool,
	pub records: &'a [Arc<Entry>],
}
pub struct Kept<'a, K> {
	pub keeper: &'a K,
	pub record: &'a Arc<Record>,
}
/// Caller-owned bounds on inputs, including duplicate rows and empty accounts.
/// A failed merge returns no partial view. Record payloads and keys are borrowed.
pub struct Limits {
	pub accounts: usize,
	pub records: usize,
}
pub fn merge<'a, K>(accounts: &[Account<'a, K>], limits: Limits) -> Result<Vec<Kept<'a, K>>, Error> {
	if accounts.len() > limits.accounts {
		return Err(Error::Capacity);
	}
	let mut rows = 0usize;
	for account in accounts {
		rows = rows.checked_add(account.records.len()).ok_or(Error::Capacity)?;
		if rows > limits.records {
			return Err(Error::Capacity);
		}
	}
	let mut positions: BTreeMap<&dyn Identity, usize> = BTreeMap::new();
	let mut winners: Vec<(usize, &Arc<Record>)> = Vec::new();
	for (account_index, account) in accounts.iter().enumerate() {
		for entry in account.records {
			let key = entry.record.as_ref() as &dyn Identity;
			if let Some(&position) = positions.get(key) {
				let (previous, record) = winners[position];
				let rank = rank(&entry.record);
				let previous_rank = self::rank(record);
				if rank > previous_rank || (rank == previous_rank && account.writes && !accounts[previous].writes) {
					winners[position] = (account_index, &entry.record);
				}
			} else {
				positions.insert(key, winners.len());
				winners.push((account_index, &entry.record));
			}
		}
	}
	Ok(winners
		.into_iter()
		.map(|(account, record)| Kept {
			keeper: accounts[account].keeper,
			record,
		})
		.collect())
}
fn rank(record: &Record) -> u8 {
	match record.body() {
		Body::Line {
			state: LineState::Withdrawn,
			..
		} => 2,
		Body::Line {
			state: LineState::Edited,
			..
		} => 1,
		_ => 0,
	}
}
