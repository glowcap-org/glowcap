//! Shared merge evidence uses real index entries; keeper and record pointers
//! prove attribution carries the original winner without copying its payload.
use rooms_application::archive::{
	index::Entry,
	merge::{merge, Account, Limits},
	Body, ConversationKind, Coordinates, Error, LineState, Record,
};
use std::sync::Arc;
fn line(id: &str, source: &str, directory: &str, state: LineState) -> Arc<Entry> {
	Arc::new(Entry {
		revision: 1,
		record: Arc::new(
			Record::new(
				Coordinates {
					source: source.into(),
					generation: "generation".into(),
					id: id.into(),
				},
				directory.into(),
				Body::Line {
					conversation_kind: ConversationKind::Direct,
					conversation: "peer".into(),
					from: "alice".into(),
					text: if state == LineState::Withdrawn { "" } else { id }.into(),
					mine: false,
					at: 1,
					order: 1,
					state,
					attachments: vec![],
				},
			)
			.unwrap(),
		),
	})
}
pub fn run() {
	captured_accounts();
	let local_keeper = String::from("local");
	let remote_keeper = String::from("selected");
	let limits = || Limits {
		accounts: 2,
		records: 8,
	};
	for (local_state, remote_state, winner) in [
		(LineState::Present, LineState::Present, 1),
		(LineState::Edited, LineState::Present, 0),
		(LineState::Present, LineState::Edited, 1),
		(LineState::Withdrawn, LineState::Edited, 0),
		(LineState::Edited, LineState::Withdrawn, 1),
		(LineState::Edited, LineState::Edited, 1),
	] {
		let local = [line("same", "source", "directory", local_state)];
		let remote = [line("same", "source", "directory", remote_state)];
		let accounts = [
			Account {
				keeper: &local_keeper,
				writes: false,
				records: &local,
			},
			Account {
				keeper: &remote_keeper,
				writes: true,
				records: &remote,
			},
		];
		let kept = merge(&accounts, limits()).unwrap();
		assert_eq!(kept.len(), 1);
		assert!(std::ptr::eq(kept[0].keeper, accounts[winner].keeper));
		assert!(Arc::ptr_eq(kept[0].record, &accounts[winner].records[0].record));
	}
	let local = [
		line("shared", "source", "directory", LineState::Present),
		line("only-local", "source", "directory", LineState::Present),
	];
	let remote = [
		line("shared", "source", "directory", LineState::Edited),
		line("only-remote", "source", "directory", LineState::Present),
		line("shared", "other-source", "directory", LineState::Present),
		line("shared", "source", "other-directory", LineState::Present),
	];
	let accounts = [
		Account {
			keeper: &local_keeper,
			writes: false,
			records: &local,
		},
		Account {
			keeper: &remote_keeper,
			writes: true,
			records: &remote,
		},
	];
	let kept = merge(&accounts, limits()).unwrap();
	assert_eq!(kept.len(), 5);
	assert!(Arc::ptr_eq(kept[0].record, &remote[0].record));
	assert!(Arc::ptr_eq(kept[1].record, &local[1].record));
	for i in 1..remote.len() {
		assert!(Arc::ptr_eq(kept[i + 1].record, &remote[i].record));
	}
	assert!(matches!(
		merge(
			&accounts,
			Limits {
				accounts: 1,
				records: 8
			}
		),
		Err(Error::Capacity)
	));
	assert!(matches!(
		merge(
			&accounts,
			Limits {
				accounts: 2,
				records: 5
			}
		),
		Err(Error::Capacity)
	));
	for writes in [false, true] {
		let a = [line("same", "source", "directory", LineState::Present)];
		let b = [line("same", "source", "directory", LineState::Present)];
		let accounts = [
			Account {
				keeper: &local_keeper,
				writes,
				records: &a,
			},
			Account {
				keeper: &remote_keeper,
				writes,
				records: &b,
			},
		];
		assert!(std::ptr::eq(
			merge(&accounts, limits()).unwrap()[0].keeper,
			&local_keeper
		));
	}
}

fn captured_accounts() {
	let fixture: serde_json::Value = serde_json::from_str(include_str!("../fixtures/archive-merge.json")).unwrap();
	for case in fixture["cases"].as_array().unwrap() {
		let sources: Vec<(String, bool, Vec<Arc<Entry>>)> = case["accounts"]
			.as_array()
			.unwrap()
			.iter()
			.map(|account| {
				let records = account["records"]
					.as_array()
					.unwrap()
					.iter()
					.map(|record| {
						Arc::new(Entry {
							revision: 1,
							record: Arc::new(serde_json::from_value::<Record>(record.clone()).unwrap()),
						})
					})
					.collect();
				(
					account["keeper"].as_str().unwrap().into(),
					account["writes"].as_bool().unwrap(),
					records,
				)
			})
			.collect();
		let accounts: Vec<_> = sources
			.iter()
			.map(|(keeper, writes, records)| Account {
				keeper,
				writes: *writes,
				records,
			})
			.collect();
		let kept = merge(
			&accounts,
			Limits {
				accounts: 2,
				records: 16,
			},
		)
		.unwrap();
		let actual: Vec<_> = kept
			.iter()
			.map(|kept| serde_json::json!({"keeper":kept.keeper, "record":kept.record}))
			.collect();
		assert_eq!(
			serde_json::Value::Array(actual),
			case["expected"],
			"merge {}",
			case["name"]
		);
	}
	let duplicate = line("same", "source", "directory", LineState::Present);
	let records = [duplicate.clone(), duplicate.clone(), duplicate];
	let account = [Account {
		keeper: &(),
		writes: true,
		records: &records,
	}];
	assert!(matches!(
		merge(
			&account,
			Limits {
				accounts: 1,
				records: 2
			}
		),
		Err(Error::Capacity)
	));
	assert!(merge::<()>(
		&[],
		Limits {
			accounts: 0,
			records: 0
		}
	)
	.unwrap()
	.is_empty());
}
