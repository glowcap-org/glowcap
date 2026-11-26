//! A held receipt identifies its access. Its ID also has to come from this
//! bot before either serving loop can take responsibility for the receipt.
use super::{Error, Name, Store};
use crate::bot::identity;
use crate::bot::ledger::{Ledger, Phase};
use std::collections::BTreeSet;

const LEGACY: &str = "legacy-action-ids.json";

pub(super) struct Origin {
	key: [u8; 16],
	legacy: Legacy,
}

/// Upgrade the IDs that local notes and reply records witness, before a start
/// can remove or replace any of those records. The old list of replaced
/// actions included any holder on the grant and cannot establish origin.
pub(in crate::bot) fn remember_start<'a>(
	store: &Store,
	ledger: &'a Ledger,
	opens: impl Iterator<Item = &'a str>,
) -> Result<(), Error> {
	let lines = ledger
		.open()
		.into_iter()
		.filter_map(|turn| match ledger.phase(turn) {
			Some(Phase::Sending { parts, .. }) => Some(parts.iter().map(|part| part.operation.as_str())),
			_ => None,
		})
		.flatten();
	Legacy::witnessed(
		store,
		opens
			.chain(lines)
			.chain(ledger.replaced().iter().map(|line| line.operation.as_str()))
			.chain(ledger.left_lines().iter().map(String::as_str)),
	)?
	.save(store)
}

struct Legacy {
	ids: BTreeSet<String>,
	saved: usize,
}

impl Legacy {
	fn witnessed<'a>(store: &Store, ids: impl Iterator<Item = &'a str>) -> Result<Self, Error> {
		let mut legacy: BTreeSet<String> = store.read(LEGACY)?.unwrap_or_default();
		if !legacy.iter().all(|id| identity::legacy_id(id)) {
			return Err(Error::unreadable(LEGACY, "invalid legacy bot action ID"));
		}
		let saved = legacy.len();
		legacy.extend(ids.filter(|id| identity::legacy_id(id)).map(str::to_owned));
		Ok(Self { ids: legacy, saved })
	}

	fn save(&self, store: &Store) -> Result<(), Error> {
		if self.ids.len() != self.saved {
			store.write(LEGACY, &self.ids)?;
		}
		Ok(())
	}
}

impl Origin {
	pub(super) fn read(store: &Store, key: [u8; 16], claims: &[Name]) -> Result<Self, Error> {
		Ok(Self {
			key,
			legacy: Legacy::witnessed(store, claims.iter().map(|name| name.operation.as_str()))?,
		})
	}

	/// Save the witnesses before the serving sweep retires their claims. A
	/// replacement's last list reads those same claims without retiring them.
	pub(super) fn remember_claims(&self, store: &Store) -> Result<(), Error> {
		self.legacy.save(store)
	}

	pub(super) fn owns(&self, id: &str) -> bool {
		self.legacy.ids.contains(id) || identity::owns_action(&self.key, id)
	}
}
