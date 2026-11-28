//! A scheduled occurrence spends the same conversation allowance as a
//! message. Its occurrence ID survives a restart; it has no activity cursor.
use super::*;
use std::collections::BTreeSet;

impl Gate {
	/// The clock has persisted the occurrence as admitting. Remember its
	/// charge until the clock acknowledges the ledger's admission, even if
	/// unrelated messages or other occurrences arrive first.
	pub fn scheduled(
		&mut self,
		store: &Store,
		conversation: &ConversationId,
		operation: &str,
		live: &BTreeSet<String>,
		cursor: Seq,
	) -> Result<bool, Error> {
		if !live.contains(operation) {
			return Ok(false);
		}
		let time = stamp::since_epoch();
		self.prune(store, cursor, time.as_secs())?;
		let (name, mut record) = self.load(store, conversation)?;
		if record.scheduled.contains(operation) {
			// The previous replace may have returned before syncing the
			// directory. Make this same charge durable before confirming it.
			store.write_in(DIRECTORY, &name, &record)?;
			return Ok(true);
		}
		if record.retry_at(time.as_secs(), self.limit).is_some() {
			return Ok(false);
		}
		record.scheduled.retain(|id| live.contains(id));
		record.scheduled.insert(operation.to_owned());
		record.charge(time);
		record.limit = self.limit;
		store.write_in(DIRECTORY, &name, &record)?;
		Ok(true)
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_testing::scratch::Scratch;

	#[test]
	fn retrying_a_charged_occurrence_after_a_restart_neither_spends_again_nor_notifies() {
		let dir = Scratch::create("scheduled-admission-charge");
		let store = Store::open(&dir).unwrap();
		let conversation = ConversationId::new("room");
		let pending = BTreeSet::from(["one".to_string(), "two".to_string()]);
		let cursor = Seq(0);
		let mut gate = Gate::new(2);
		assert!(gate.scheduled(&store, &conversation, "one", &pending, cursor).unwrap());
		let mut gate = Gate::new(2);
		assert!(gate.scheduled(&store, &conversation, "one", &pending, cursor).unwrap());
		let request = super::super::tests::event(1);
		assert_eq!(
			gate.decide(&store, &conversation, &request, cursor).unwrap(),
			Decision::Start
		);
		assert!(!gate.scheduled(&store, &conversation, "two", &pending, cursor).unwrap());
		assert!(report(store.root(), Some(2)).unwrap().is_empty());
		let refused = super::super::tests::event(2);
		assert!(matches!(
			gate.decide(&store, &conversation, &refused, cursor).unwrap(),
			Decision::Notify(_)
		));
		assert!(gate.scheduled(&store, &conversation, "one", &pending, cursor).unwrap());
		assert_eq!(report(store.root(), Some(2)).unwrap()[&conversation].skipped, 1);
	}
}
