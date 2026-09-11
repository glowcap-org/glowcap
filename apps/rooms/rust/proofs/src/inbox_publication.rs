use rooms_application::{
	direct::publication::{Error, Ledger},
	directory::registration::Id,
};
fn id(n: usize) -> Id {
	Id::parse(&format!("{n:08x}-1111-4111-8111-111111111111")).unwrap()
}
pub fn run() {
	let capture: serde_json::Value = serde_json::from_str(include_str!("../fixtures/inbox-publication.json")).unwrap();
	let mut ledger = Ledger::new(2).unwrap();
	let scopes = [ledger.scope().unwrap(), ledger.scope().unwrap()];
	let (mut published, mut removed, mut offered, mut errors) = (0, 0, 0, 0);
	let mut entropy = 0u8;
	for row in capture["trace"].as_array().unwrap() {
		let scope = &scopes[row["owner"].as_u64().unwrap() as usize];
		match row["op"].as_str().unwrap() {
			"offer" => {
				entropy += 1;
				match ledger.reserve(
					scope,
					row["peer"].as_str().unwrap(),
					&id(row["id"].as_u64().unwrap() as usize),
					[entropy; 32],
				) {
					Ok(inbox) => {
						if !inbox.published() {
							ledger.published(&inbox).unwrap();
							published += 1;
						}
						offered += 1;
					}
					Err(_) => errors += 1,
				}
			}
			"forget" => ledger.forget(scope, &id(row["id"].as_u64().unwrap() as usize)).unwrap(),
			"close" => scope.close(),
			_ => unreachable!(),
		}
		for inbox in ledger.retirements() {
			ledger.removed(&inbox).unwrap();
			removed += 1;
		}
		for (name, value) in [
			("published", published),
			("removed", removed),
			("offered", offered),
			("errors", errors),
		] {
			assert_eq!(row[name], serde_json::json!(value), "{row}");
		}
	}
	let mut ledger = Ledger::new(2).unwrap();
	let one = ledger.scope().unwrap();
	let two = ledger.scope().unwrap();
	let first = ledger.reserve(&one, "alice", &id(1), [1; 32]).unwrap();
	assert!(first.publishable());
	assert_eq!(ledger.held(), 1);
	assert!(!first.live());
	assert_eq!(
		ledger.reserve(&one, "alice", &id(1), [2; 32]).unwrap().alias(),
		first.alias()
	);
	assert!(matches!(ledger.existing(&one, "bob", &id(1)), Err(Error::Registration)));
	ledger.published(&first).unwrap();
	assert!(!first.publishable());
	assert!(first.live());
	let second = ledger.reserve(&two, "alice", &id(1), [2; 32]).unwrap();
	ledger.published(&second).unwrap();
	assert_ne!(first.alias(), second.alias());
	assert!(matches!(ledger.reserve(&one, "bob", &id(2), [3; 32]), Err(Error::Full)));
	ledger.forget(&one, &id(1)).unwrap();
	assert!(!first.live());
	assert!(second.live());
	let retired = ledger.retirements();
	assert_eq!(retired.len(), 1);
	// A failed native remove changes neither authority nor capacity. Retrying
	// returns the same exact alias instead of losing its bookkeeping.
	assert_eq!(ledger.held(), 2);
	assert_eq!(ledger.retirements()[0].alias(), first.alias());
	ledger.removed(&retired[0]).unwrap();
	assert_eq!(ledger.held(), 1);
	let later = ledger.reserve(&one, "alice", &id(1), [3; 32]).unwrap();
	assert_ne!(later.alias(), first.alias());
	ledger.published(&later).unwrap();
	assert!(later.live());
	assert!(!first.live());
	one.close();
	assert!(!later.live());
	assert!(second.live());
	assert!(matches!(ledger.existing(&one, "alice", &id(1)), Err(Error::Closed)));
	for row in ledger.retirements() {
		ledger.removed(&row).unwrap();
	}
	drop(two);
	assert!(!second.live());
	for row in ledger.retirements() {
		ledger.removed(&row).unwrap();
	}
	assert_eq!(ledger.held(), 0);
	let closing = ledger.scope().unwrap();
	let cancelled = ledger.reserve(&closing, "alice", &id(1), [5; 32]).unwrap();
	assert!(cancelled.publishable());
	closing.close();
	assert!(!cancelled.publishable());
	ledger.abandon(&cancelled).unwrap();
	let active = ledger.scope().unwrap();
	let provisional = ledger.reserve(&active, "alice", &id(1), [4; 32]).unwrap();
	assert!(matches!(
		ledger.reserve(&active, "bob", &id(2), [4; 32]),
		Err(Error::Collision)
	));
	ledger.abandon(&provisional).unwrap();
	assert!(!provisional.publishable());
	assert_eq!(ledger.held(), 0);
	assert!(ledger.published(&provisional).is_err());
	let foreign = Ledger::new(2).unwrap().scope().unwrap();
	assert!(matches!(
		ledger.reserve(&foreign, "alice", &id(1), [0; 32]),
		Err(Error::Foreign)
	));
	assert!(matches!(
		ledger.reserve(&active, "room", &id(1), [0; 32]),
		Err(Error::Peer)
	));
	assert!(Ledger::new(0).is_err());
	let default = capture["defaultLimit"].as_u64().unwrap() as usize;
	assert_eq!(default, rooms_application::direct::publication::DEFAULT_INBOX_LIMIT);
	let total = capture["ircLimit"].as_u64().unwrap() as usize;
	let mut ledger = Ledger::new(total).unwrap();
	let mut scopes = Vec::new();
	for index in 0..total {
		if index % default == 0 {
			scopes.push(ledger.scope().unwrap());
		}
		let scope = scopes.last().unwrap();
		let mut entropy = [0; 32];
		entropy[..8].copy_from_slice(&(index as u64).to_le_bytes());
		let inbox = ledger.reserve(scope, "alice", &id(index % default), entropy).unwrap();
		ledger.published(&inbox).unwrap();
	}
	assert_eq!(ledger.held(), total);
	assert!(matches!(
		ledger.reserve(&scopes[0], "alice", &id(total), [255; 32]),
		Err(Error::Full)
	));
	for scope in scopes {
		scope.close();
	}
	for inbox in ledger.retirements() {
		ledger.removed(&inbox).unwrap();
		assert!(!inbox.live());
	}
	assert_eq!(ledger.held(), 0);
}
