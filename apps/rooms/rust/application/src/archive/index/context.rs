//! Conversation chronology shares Entry backing. One tree node and Arc per
//! retained record, bounded by Index capacity. Borrowed bounds copy no payload
//! or contextual strings. Exact conversation reads visit only that conversation.
use super::Entry;
use crate::{
	archive::{ConversationKind, Filter, Kind},
	text::DocumentText,
};
use alloc::{borrow::Borrow, collections::BTreeSet, sync::Arc};
use core::{cmp::Ordering, ops::Bound};

type Parts<'a> = (Kind, Option<ConversationKind>, &'a DocumentText, &'a DocumentText, u64);
trait Position {
	fn parts(&self) -> Parts<'_>;
}
impl Position for Entry {
	fn parts(&self) -> Parts<'_> {
		(
			self.record.kind(),
			self.record.conversation_kind(),
			self.record.directory(),
			self.record.conversation(),
			self.revision,
		)
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::archive::{Body, Coordinates, LineState, MAX_RECORDS, Record, index::Index};
	fn line(conversation: &str, source: &str, text: &str) -> Record {
		Record::new(
			Coordinates {
				source: source.into(),
				generation: "generation".into(),
				id: "line".into(),
			},
			"directory".into(),
			Body::Line {
				conversation_kind: ConversationKind::Room,
				conversation: conversation.into(),
				from: "alice".into(),
				text: text.into(),
				mine: false,
				at: 1,
				order: 1,
				state: LineState::Present,
				previews: Default::default(),
				attachments: alloc::vec![],
			},
		)
		.unwrap()
	}
	#[test]
	fn conversation_traversal_and_index_retirement() {
		let mut index = Index::new(MAX_RECORDS).unwrap();
		let filter = Filter {
			kind: Some(Kind::Line),
			conversation_kind: Some(ConversationKind::Room),
			directory: Some("directory".into()),
			conversation: Some("target".into()),
			..Default::default()
		};
		index.apply(1, line("target", "owner", "first")).unwrap();
		for revision in 2..=MAX_RECORDS as u64 {
			index
				.apply(
					revision,
					line(&alloc::format!("other-{revision}"), "other", "unrelated"),
				)
				.unwrap();
		}
		assert_eq!(
			index.contexts.range(&filter, 0).count(),
			1,
			"only one candidate visited at the full account ceiling"
		);
		let prior = Arc::downgrade(&index.read(&filter, 0, 1).unwrap().records[0]);
		index
			.apply(MAX_RECORDS as u64 + 1, line("target", "owner", "edited"))
			.unwrap();
		assert!(
			prior.upgrade().is_none(),
			"replacement releases the old entry from all indexes"
		);
		assert_eq!(index.contexts.range(&filter, 0).count(), 1);
		let entries = index
			.snapshot()
			.map(|entry| Entry {
				revision: entry.revision,
				record: entry.record.clone(),
			})
			.collect();
		let mut restored = Index::new(MAX_RECORDS).unwrap();
		restored.restore(index.revision(), entries).unwrap();
		assert_eq!(
			restored.read(&filter, 0, 1).unwrap().records[0].revision,
			MAX_RECORDS as u64 + 1
		);
		index.clear_source(&"owner".into());
		assert_eq!(index.contexts.range(&filter, 0).count(), 0);
		let current = Arc::downgrade(&restored.read(&filter, 0, 1).unwrap().records[0]);
		restored.clear();
		assert!(current.upgrade().is_none());
		let mut evicting = Index::new(1).unwrap();
		evicting.apply(1, line("target", "owner", "first")).unwrap();
		evicting.apply(2, line("other", "other", "second")).unwrap();
		assert_eq!(evicting.contexts.range(&filter, 0).count(), 0);
	}
}
impl Position for Parts<'_> {
	fn parts(&self) -> Parts<'_> {
		*self
	}
}
impl PartialEq for dyn Position + '_ {
	fn eq(&self, other: &Self) -> bool {
		self.parts() == other.parts()
	}
}
impl Eq for dyn Position + '_ {}
impl PartialOrd for dyn Position + '_ {
	fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
		Some(self.cmp(other))
	}
}
impl Ord for dyn Position + '_ {
	fn cmp(&self, other: &Self) -> Ordering {
		self.parts().cmp(&other.parts())
	}
}
struct Key(Arc<Entry>);
impl<'a> Borrow<dyn Position + 'a> for Key {
	fn borrow(&self) -> &(dyn Position + 'a) {
		self.0.as_ref()
	}
}
impl PartialEq for Key {
	fn eq(&self, other: &Self) -> bool {
		self.0.parts() == other.0.parts()
	}
}
impl Eq for Key {}
impl PartialOrd for Key {
	fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
		Some(self.cmp(other))
	}
}
impl Ord for Key {
	fn cmp(&self, other: &Self) -> Ordering {
		self.0.parts().cmp(&other.0.parts())
	}
}
#[derive(Default)]
pub(super) struct Contexts(BTreeSet<Key>);
impl Contexts {
	pub fn insert(&mut self, entry: Arc<Entry>) {
		self.0.insert(Key(entry));
	}
	pub fn remove(&mut self, entry: &Entry) {
		self.0.remove(entry as &dyn Position);
	}
	pub fn clear(&mut self) {
		self.0.clear();
	}
	pub fn clear_source(&mut self, source: &DocumentText) {
		self.0.retain(|key| &key.0.record.coordinates().source != source);
	}
	pub fn selected(filter: &Filter) -> bool {
		filter.kind == Some(Kind::Line)
			&& filter.conversation_kind.is_some()
			&& filter.directory.is_some()
			&& filter.conversation.is_some()
	}
	pub fn range<'a>(&'a self, filter: &Filter, after: u64) -> impl Iterator<Item = &'a Arc<Entry>> {
		// A filter that selects no exact conversation has no context to walk.
		let walk = filter
			.directory
			.as_ref()
			.zip(filter.conversation.as_ref())
			.map(|(directory, conversation)| {
				let lower = (Kind::Line, filter.conversation_kind, directory, conversation, after);
				let upper = (lower.0, lower.1, lower.2, lower.3, u64::MAX);
				self.0
					.range::<dyn Position, _>((
						Bound::Excluded(&lower as &dyn Position),
						Bound::Included(&upper as &dyn Position),
					))
					.map(|key| &key.0)
			});
		walk.into_iter().flatten()
	}
}
