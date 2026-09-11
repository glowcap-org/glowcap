use super::*;
use rooms_application::session::checkpoint::reconciliation::Id;

#[test]
fn notification_admission_counts_held_work_and_retained_text_capacity() {
	let budget = NoticeBudget::default();
	let key = Generation::new(Rc::new(Id::new("directory".into()).unwrap()));
	let event = registration::Event {
		kind: registration::Kind::MintInboxFor,
		peer: rooms_application::fields::Text::new("bob".into()).unwrap(),
		registration: registration::Id::parse("11111111-1111-4111-8111-111111111111").unwrap(),
	};
	let mut held: Vec<_> = (0..REGISTRATION_LIMIT)
		.map(|_| budget.reserve(&key, &event).unwrap())
		.collect();
	key.scope.retire();
	assert!(
		budget.reserve(&key, &event).is_none(),
		"retiring a generation does not drop its handed-out work"
	);
	held.pop();
	assert!(budget.reserve(&key, &event).is_some());
	drop(held);
	let mut spare = String::with_capacity(REGISTRATION_BYTES);
	spare.push_str("directory");
	let large = Generation::new(Rc::new(Id::new(spare.into()).unwrap()));
	assert!(
		budget.reserve(&large, &event).is_none(),
		"short visible text can retain an oversized allocation"
	);
	assert!(
		budget.reserve(&key, &event).is_some(),
		"refused admission spends no budget"
	);
}
