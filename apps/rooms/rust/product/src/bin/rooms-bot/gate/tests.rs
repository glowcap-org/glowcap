use super::*;
use crate::bot::rooms::Cursor;

pub(super) fn event(n: u64) -> Trigger {
	Trigger {
		opening_until: None,
		scope: None,
		seq: Seq(n),
		event: Cursor::new(format!("e{n}")).unwrap(),
		line: String::new(),
		text: String::new(),
		from: None,
		files: vec![],
	}
}

#[test]
fn rolling_expiry_replay_and_cost_changes() {
	let mut row = Record {
		conversation: ConversationId::new("c"),
		starts: VecDeque::new(),
		last: None,
		scheduled: BTreeSet::new(),
		notice: None,
		skipped: 0,
		limit: 2,
	};
	assert_eq!(row.decide(&event(1), Duration::from_secs(100), 2), Decision::Start);
	assert_eq!(row.decide(&event(2), Duration::from_secs(200), 2), Decision::Start);
	assert_eq!(
		row.decide(&event(3), Duration::from_secs(300), 2),
		Decision::Notify(3700)
	);
	assert_eq!(
		row.decide(&event(3), Duration::from_secs(3900), 2),
		Decision::Notify(3700)
	);
	assert_eq!(row.decide(&event(4), Duration::from_secs(3699), 2), Decision::Skip);
	assert_eq!(row.retry_at(3699, 1), Some(3800));
	assert_eq!(row.retry_at(3700, 2), None);
	let before = serde_json::to_vec(&row).unwrap();
	let mut lowered: Record = serde_json::from_slice(&before).unwrap();
	assert_eq!(
		lowered.decide(&event(5), Duration::from_secs(3700), 1),
		Decision::Notify(3800)
	);
	assert_eq!(lowered.decide(&event(6), Duration::from_secs(3799), 1), Decision::Skip);
	assert_eq!(lowered.decide(&event(7), Duration::from_secs(3800), 1), Decision::Start);
	assert_eq!(row.decide(&event(5), Duration::from_secs(3700), 2), Decision::Start);
	assert_eq!(
		row.decide(&event(6), Duration::from_secs(3700), 2),
		Decision::Notify(3800)
	);
	assert_eq!(
		row.decide(&event(7), Duration::from_millis(7_400_999), 1),
		Decision::Start
	);
	assert_eq!(row.retry_at(11_000, 1), Some(11_001));
	assert_eq!(row.retry_at(11_001, 1), None);
	assert!(is_notice(&message(3800)));
	assert!(!is_notice(&format!("{} please explain", message(3800))));
}
