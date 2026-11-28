//! Admission against a real ledger: more conversations than the ledger has
//! rows, with triggers before and after the one that waits.
use super::*;
use crate::bot::{
	classify::{Seq, Trigger},
	ledger::{MAX_OPEN, MAX_ROWS, Phase, TurnId},
	rooms::{Cursor, Kind},
};
use rooms_testing::scratch::Scratch;

fn queued(seq: u64) -> Queued {
	Queued {
		kind: Kind::Direct,
		trigger: Trigger {
			opening_until: None,
			scope: None,
			seq: Seq(seq),
			event: Cursor::new(format!("e{seq}")).unwrap(),
			line: format!("l{seq}"),
			from: None,
			text: String::new(),
			files: Vec::new(),
		},
		before: Cursor::new(format!("e{}", seq - 1)).unwrap(),
	}
}

/// One settle as `Loop::settle` runs it: hold, start, and move the cursor,
/// then once more when the cursor move freed rows a waiting trigger needs.
/// Returns the turns it started.
fn settle(lanes: &mut Lanes, ledger: &mut Ledger, store: &Store, read: u64) -> Vec<(ConversationId, TurnId)> {
	let mut started = Vec::new();
	for round in 0..2 {
		if round == 1 && (lanes.oldest_waiting().is_none() || !ledger.has_room()) {
			break;
		}
		hold(lanes, ledger, store, &mut Gate::new(1000), &mut Vec::new()).unwrap();
		while let Some((conversation, id)) = lanes.next() {
			lanes.started(&conversation);
			started.push((conversation, id));
		}
		let (cursor, seq) = lanes.oldest_waiting().map_or(
			(Cursor::new(format!("e{read}")).unwrap(), Seq(read + 1)),
			|(before, seq)| (before.clone(), seq),
		);
		ledger.advance(store, &cursor, seq).unwrap();
	}
	started
}

/// Conversations past the ledger's rows each ask once, one more asks, and
/// then each of the first asks again. Every trigger gets a turn, in read
/// order within each conversation, and the ledger holds no finished row after
/// a settle, so the one that waited is never kept out for good.
#[test]
fn the_oldest_unheld_trigger_gets_a_turn_once_the_turns_older_than_it_end() {
	let dir = Scratch::create("bot-intake-wedge");
	let store = Store::open(&dir).unwrap();
	let mut ledger = Ledger::start(&store, Cursor::start()).unwrap();
	let mut lanes = Lanes::default();
	let crowd = MAX_ROWS as u64;
	let conversation = |seq: u64| {
		ConversationId::new(match seq {
			seq if seq <= crowd => format!("c{seq}"),
			seq if seq == crowd + 1 => "x".to_owned(),
			seq => format!("c{}", seq - crowd - 1),
		})
	};
	let last = 2 * crowd + 1;
	for seq in 1..=last {
		lanes.queue(&conversation(seq), queued(seq));
	}
	let mut running = std::collections::VecDeque::from(settle(&mut lanes, &mut ledger, &store, last));
	let mut held: BTreeMap<ConversationId, Vec<u64>> = BTreeMap::new();
	let mut ended = 0;
	while let Some((conversation, id)) = running.pop_front() {
		let Some(Phase::Running { asked, .. }) = ledger.phase(id) else {
			panic!("turn {id:?} is not running");
		};
		held.entry(conversation.clone())
			.or_default()
			.extend(asked.triggers.iter().map(|trigger| trigger.seq.0));
		ledger.done(&store, id).unwrap();
		lanes.release(&conversation);
		running.extend(settle(&mut lanes, &mut ledger, &store, last));
		ended += 1;
		assert!(ended <= last, "more turns ended than there are triggers");
		assert_eq!(
			ledger.open().len(),
			rows_on_disk(&store),
			"a finished row outlived a settle"
		);
		assert!(ledger.open().len() <= MAX_OPEN);
	}
	assert_eq!(lanes.waiting(), 0, "a trigger never got a turn");
	let all: BTreeSet<u64> = held.values().flatten().copied().collect();
	assert_eq!(all, (1..=last).collect(), "a trigger was held twice or never");
	for seqs in held.values() {
		assert!(seqs.is_sorted(), "a conversation's turns ran out of order: {seqs:?}");
	}
	assert_eq!(ledger.cursor_seq(), Seq(last + 1));
}

/// How many rows the ledger file holds, open or finished.
fn rows_on_disk(store: &Store) -> usize {
	let file: serde_json::Value =
		serde_json::from_slice(&std::fs::read(store.root().join(crate::bot::ledger::FILE)).unwrap()).unwrap();
	file["turns"].as_array().unwrap().len()
}
