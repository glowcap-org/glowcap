//! A scheduled occurrence spends the same conversation allowance as a
//! message. Its occurrence ID survives a restart; it has no activity cursor.
use super::*;
use std::collections::BTreeSet;

#[derive(Debug, PartialEq, Eq)]
pub enum ScheduledDecision {
	Start,
	RetryAt { until: u64, limit: u32 },
}

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
	) -> Result<ScheduledDecision, Error> {
		let time = stamp::since_epoch();
		self.prune(store, cursor, time.as_secs())?;
		let (name, mut record) = self.load(store, conversation)?;
		if record.scheduled.contains(operation) {
			// The previous replace may have returned before syncing the
			// directory. Make this same charge durable before confirming it.
			store.write_in(DIRECTORY, &name, &record)?;
			return Ok(ScheduledDecision::Start);
		}
		if let Some(until) = record.retry_at(time.as_secs(), self.limit) {
			return Ok(ScheduledDecision::RetryAt {
				until,
				limit: self.limit,
			});
		}
		record.scheduled.retain(|id| live.contains(id));
		record.scheduled.insert(operation.to_owned());
		record.charge(time);
		record.limit = self.limit;
		store.write_in(DIRECTORY, &name, &record)?;
		Ok(ScheduledDecision::Start)
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
		assert_eq!(
			gate.scheduled(&store, &conversation, "one", &pending, cursor).unwrap(),
			ScheduledDecision::Start
		);
		let mut gate = Gate::new(2);
		assert_eq!(
			gate.scheduled(&store, &conversation, "one", &pending, cursor).unwrap(),
			ScheduledDecision::Start
		);
		let request = super::super::tests::event(1);
		assert_eq!(
			gate.decide(&store, &conversation, &request, cursor).unwrap(),
			Decision::Start
		);
		let limited = gate.scheduled(&store, &conversation, "two", &pending, cursor).unwrap();
		assert!(report(store.root(), Some(2)).unwrap().is_empty());
		let refused = super::super::tests::event(2);
		let Decision::Notify(until) = gate.decide(&store, &conversation, &refused, cursor).unwrap() else {
			panic!("an exhausted conversation had no retry time");
		};
		assert_eq!(limited, ScheduledDecision::RetryAt { until, limit: 2 });
		assert_eq!(
			gate.scheduled(&store, &conversation, "one", &pending, cursor).unwrap(),
			ScheduledDecision::Start
		);
		assert_eq!(report(store.root(), Some(2)).unwrap()[&conversation].skipped, 1);
	}
}
