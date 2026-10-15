//! The command owner runs unchanged in the host and portable Wasm contracts.
use rooms_application::{
	session::{
		controller::{Authority, Commands, Error, MAX_RETAINED_RESULTS, Pending, Step},
		state::{self, OperationId},
	},
	text::DocumentText,
};

fn id(value: &str) -> OperationId {
	OperationId::new(value.into()).unwrap()
}
fn driving(commands: &Commands) -> Vec<String> {
	commands
		.driving()
		.iter()
		.map(|id| id.text().as_str().unwrap().into())
		.collect()
}
pub fn run() {
	retries();
	results();
	managed();
	bounds();
	identities();
}
fn identities() {
	let commands = Commands::default();
	// A non-scalar operation id is retained exactly, not folded to a scalar.
	let surrogate = OperationId::new(DocumentText::from_utf16(&[0xd800])).unwrap();
	let operation = commands
		.begin("setStanding", surrogate.clone(), |_| Ok(vec![]))
		.unwrap();
	assert_eq!(operation.id(), &surrogate);
	drop(operation);
	// A result-bearing command retains its first identity across an abandoned
	// observation, and a later candidate answering the same intent inherits it.
	let lost = id("lost");
	drop(
		commands
			.begin("takeRoomModerator", lost.clone(), |_| {
				Ok(vec!["room".into(), "manager".into()])
			})
			.unwrap(),
	);
	let candidate = commands
		.begin("takeRoomModerator", id("candidate"), |_| {
			Ok(vec!["room".into(), "manager".into()])
		})
		.unwrap();
	assert_eq!(candidate.id(), &lost, "an abandoned result keeps its first identity");
}
fn retries() {
	let commands = Commands::default();
	let mut operation = commands
		.begin("setStanding", id("pure"), |_| {
			panic!("ordinary text must not be copied")
		})
		.unwrap();
	assert_eq!(operation.step(), Step::Issue);
	assert!(driving(&commands).is_empty());
	assert!(matches!(
		commands.begin("say", id("overlap"), |_| Ok(vec![])),
		Err(Error::Busy)
	));
	assert!(
		operation
			.refused(&format!("glowcap error -2: {}", state::Error::Revision))
			.unwrap()
	);
	assert_eq!(operation.step(), Step::Refresh);
	operation.refreshed([]).unwrap();
	assert!(!operation.refused(&state::Error::Revision.to_string()).unwrap());
	drop(operation);
	let mut operation = commands
		.begin("setStanding", id("acknowledged"), |_| panic!("ordinary text copied"))
		.unwrap();
	operation.acknowledged(7).unwrap();
	assert_eq!(operation.step(), Step::SettleCommand(7));
	assert_eq!(operation.refused(&state::Error::Revision.to_string()), Err(Error::Step));
	operation.committed().unwrap();
	assert_eq!(operation.step(), Step::Done);
	drop(operation);
	let mut operation = commands
		.begin("say", id("line"), |_| panic!("ordinary text copied"))
		.unwrap();
	assert_eq!(driving(&commands), ["line"]);
	assert!(!operation.refused(&state::Error::Revision.to_string()).unwrap());
	drop(operation);
	assert!(driving(&commands).is_empty());
	let reentrant = Commands::default();
	assert!(matches!(
		reentrant.begin("ensureRoomLink", id("reentrant"), |_| {
			assert!(reentrant.driving().is_empty());
			reentrant.close();
			Ok(vec!["room".into()])
		}),
		Err(Error::Closed)
	));
	commands.close();
	assert!(matches!(
		commands.begin("say", id("closed"), |_| Ok(vec![])),
		Err(Error::Closed)
	));
}
fn results() {
	let commands = Commands::default();
	let begin = |candidate| {
		commands
			.begin("takeRoomManager", id(candidate), |_| {
				Ok(vec!["room".into(), "manager".into()])
			})
			.unwrap()
	};
	let operation = begin("original");
	assert_eq!(operation.step(), Step::Refresh);
	drop(operation); // An abandoned observation retains the request identity.
	let mut operation = begin("retry");
	assert_eq!(operation.id(), &id("original"));
	let external: DocumentText = "external".into();
	let kind: DocumentText = "room-manager".into();
	let pending: DocumentText = "original".into();
	let subject: DocumentText = "Restore room manager".into();
	operation
		.refreshed([
			Pending {
				id: &pending,
				kind: &external,
				subject: &subject,
			},
			Pending {
				id: &pending,
				kind: &kind,
				subject: &subject,
			},
		])
		.unwrap();
	assert_eq!(operation.step(), Step::Resume);
	assert_eq!(driving(&commands), ["original"], "resuming our own id is one claim");
	operation.acknowledged(8).unwrap();
	let room: DocumentText = "room".into();
	let manager: DocumentText = "manager".into();
	operation
		.resumed([Authority {
			id: &room,
			link: None,
			manager: Some(&manager),
			steward: None,
		}])
		.unwrap();
	assert_eq!(operation.step(), Step::Done);
	assert_eq!(
		driving(&commands),
		["original"],
		"resume observation must not prematurely release the outer claim"
	);
	drop(operation);
	let operation = begin("next");
	assert_eq!(operation.id(), &id("next"));
	drop(operation);
	let operation = commands
		.begin("takeRoomManager", id("corrected"), |_| {
			Ok(vec!["room".into(), "other-manager".into()])
		})
		.unwrap();
	assert_eq!(operation.id(), &id("corrected"));
	drop(operation);
	let mut operation = begin("restored-intent");
	assert_eq!(operation.id(), &id("restored-intent"));
	operation.refreshed([]).unwrap();
	assert!(operation.refused(&state::Error::ResultInFlight.to_string()).unwrap());
	operation.refreshed([]).unwrap();
	assert!(!operation.refused(&state::Error::ResultInFlight.to_string()).unwrap());
}
fn managed() {
	let commands = Commands::default();
	let args = |_| {
		Ok(vec![
			r#"{"id":"room","name":"general"}"#.into(),
			"recovery".into(),
			"listed".into(),
			"open".into(),
			"everyone".into(),
		])
	};
	let mut operation = commands.begin("openManagedRoom", id("managed"), args).unwrap();
	let pending: DocumentText = "prior".into();
	let kind: DocumentText = "managed-room".into();
	let subject: DocumentText = "Create room".into();
	operation
		.refreshed([Pending {
			id: &pending,
			kind: &kind,
			subject: &subject,
		}])
		.unwrap();
	assert_eq!(driving(&commands), ["managed", "prior"]);
	operation.acknowledged(1).unwrap();
	let room: DocumentText = "room".into();
	operation
		.resumed([Authority {
			id: &room,
			link: None,
			manager: None,
			steward: None,
		}])
		.unwrap();
	assert_eq!(
		operation.step(),
		Step::Issue,
		"a matching id alone is not a returned room authority"
	);
	assert_eq!(driving(&commands), ["managed"]);
	drop(operation);
	let mut operation = commands.begin("openManagedRoom", id("retry"), args).unwrap();
	assert_eq!(operation.id(), &id("managed"));
	operation
		.refreshed([Pending {
			id: &pending,
			kind: &kind,
			subject: &subject,
		}])
		.unwrap();
	operation.acknowledged(2).unwrap();
	let link: DocumentText = "room-link".into();
	operation
		.resumed([Authority {
			id: &room,
			link: Some(&link),
			manager: None,
			steward: None,
		}])
		.unwrap();
	assert_eq!(operation.step(), Step::Done);
}
fn bounds() {
	let commands = Commands::default();
	for index in 0..MAX_RETAINED_RESULTS {
		let target = format!("room-{index}");
		drop(
			commands
				.begin("ensureRoomLink", id(&target), |_| Ok(vec![target.as_str().into()]))
				.unwrap(),
		);
	}
	assert!(matches!(
		commands.begin("ensureRoomLink", id("overflow"), |_| Ok(vec!["new-room".into()])),
		Err(Error::Full)
	));
	let mut retry = commands
		.begin("ensureRoomLink", id("retry"), |_| Ok(vec!["room-0".into()]))
		.unwrap();
	assert_eq!(
		retry.id(),
		&id("room-0"),
		"pressure must not evict an unanswered identity"
	);
	retry.refreshed([]).unwrap();
	retry.acknowledged(1).unwrap();
	retry.committed().unwrap();
	drop(retry);
	drop(
		commands
			.begin("ensureRoomLink", id("available"), |_| Ok(vec!["new-room".into()]))
			.unwrap(),
	);
	commands.close();
	let commands = Commands::default();
	let material = "😀".repeat(32768);
	let mut admitted = 0;
	for index in 0..64 {
		let result = commands.begin("takeRoomManager", id("large"), |_| {
			Ok(vec![format!("room-{index}").into(), material.as_str().into()])
		});
		match result {
			Ok(operation) => {
				admitted += 1;
				drop(operation);
			}
			Err(Error::Full) => break,
			Err(error) => panic!("{error}"),
		}
	}
	assert!(
		(1..64).contains(&admitted),
		"retained bytes must be bounded independently of the slot count"
	);
}
