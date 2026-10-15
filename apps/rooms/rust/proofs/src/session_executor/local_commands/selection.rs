//! Current session admission authorizes selection of checked custody even
//! after upstream revocation. Candidate and receipt rollback/replay share it.
use super::*;
use rooms_application::content::session::local::ArchiveSelection;

pub(super) struct Replay {
	derivation: Vec<Argument>,
	commands: Vec<Vec<Argument>>,
}
impl Replay {
	pub(super) async fn replay(&self, host: &Host, root: &Ref, other: &Ref) {
		let restored = host.send(root, "derive-managed", &self.derivation).await.unwrap();
		let source = Ref::try_from(&restored.as_list().unwrap()[0]).unwrap();
		let current = snapshot(host, &source).await;
		for command in &self.commands {
			assert!(mutate(host, other, "command", command).await.is_err());
			assert_eq!(
				mutate(host, &source, "command", command).await.unwrap().as_str(),
				Some("committed")
			);
			assert_eq!(
				snapshot(host, &source).await,
				current,
				"cold replay changes no selection"
			);
		}
	}
}

pub(super) async fn run(
	host: &Host,
	owner: &managed::Session<Platform>,
	root: &Ref,
	policy: &loam::Policy,
	ordinary: &Ref,
	target: &Ref,
	audit: (&Cell<bool>, &Cell<usize>),
) -> Replay {
	let (refuse, requests) = audit;
	let terms = policy
		.value_for_kind(
			session::KIND,
			&[
				Permission::ObserveWorkspace.key(),
				Permission::InteractWorkspace.key(),
				Permission::ManageCustody.key(),
			],
			&[],
		)
		.unwrap();
	let sequence = host
		.send(root, "derivation-sequence", &[])
		.await
		.unwrap()
		.as_i64()
		.unwrap() as u32;
	let derivation = terms.managed_derive_arguments(sequence, Scope::Object, 1, ControlPowers::default());
	let (source, _) = owner.derive(terms, 1, ControlPowers::default()).await.unwrap();
	for role in [
		custody::Role::RoomControl,
		custody::Role::ArchiveAccess,
		custody::Role::ArchiveControl,
		custody::Role::Operator,
		custody::Role::RoomAccess,
	] {
		let key = if role == custody::Role::RoomAccess {
			custody::FieldKey::new(NonZeroU64::new(3).unwrap(), NonZeroU64::new(1).unwrap())
		} else {
			key()
		};
		owner
			.import(custody::Coordinate { role, key }, target.clone(), None)
			.await
			.unwrap();
	}
	let existing = serde_json::to_string(&key::<custody::RoomControl>()).unwrap();
	let moderator = serde_json::to_string(&custody::FieldKey::<custody::RoomAccess>::new(
		NonZeroU64::new(3).unwrap(),
		NonZeroU64::new(1).unwrap(),
	))
	.unwrap();
	let archive = serde_json::to_string(&ArchiveSelection {
		access: key(),
		control: Some(key()),
	})
	.unwrap();
	let operators = serde_json::to_string(&[key::<custody::Operator>()]).unwrap();
	let missing = serde_json::to_string(&custody::FieldKey::<custody::RoomControl>::new(
		NonZeroU64::new(99).unwrap(),
		NonZeroU64::new(1).unwrap(),
	))
	.unwrap();
	let before = snapshot(host, &source).await;
	assert!(
		mutate(
			host,
			&source,
			"command",
			&args(
				"missing-selection",
				before.0,
				"takeRoomManager",
				&["conversation", &missing]
			)
		)
		.await
		.is_err()
	);
	assert_eq!(snapshot(host, &source).await, before);
	let mut commands = Vec::new();
	for (name, rest) in [
		("takeRoomLink", vec!["conversation", existing.as_str()]),
		("takeRoomModerator", vec!["conversation", moderator.as_str()]),
		("takeRoomManager", vec!["conversation", existing.as_str()]),
		("selectArchive", vec![archive.as_str()]),
		("replaceOperationsCapabilities", vec![operators.as_str()]),
	] {
		let before = snapshot(host, &source).await;
		let command = args(&format!("select-{name}"), before.0, name, &rest);
		assert!(
			mutate(host, ordinary, "command", &command).await.is_err(),
			"ManageCustody is independent of InteractWorkspace"
		);
		assert_eq!(snapshot(host, &source).await, before);
		refuse.set(true);
		assert!(mutate(host, &source, "command", &command).await.is_err());
		assert_eq!(
			snapshot(host, &source).await,
			before,
			"selection and receipt rolled back"
		);
		assert_eq!(requests.get(), 0);
		refuse.set(false);
		assert_eq!(
			mutate(host, &source, "command", &command).await.unwrap().as_str(),
			Some("committed")
		);
		assert_eq!(
			requests.get(),
			0,
			"selecting checked custody restores no revoked upstream grant"
		);
		let after = snapshot(host, &source).await;
		assert_eq!(
			mutate(host, &source, "command", &command).await.unwrap().as_str(),
			Some("committed")
		);
		assert_eq!(snapshot(host, &source).await, after);
		commands.push(command);
	}
	let intent = snapshot(host, &source).await.1;
	let workspace::Conversation::Room(room) = &intent.conversations.as_slice()[0] else {
		panic!("room");
	};
	assert!(room.access.is_some() && room.moderator.is_some() && room.control.is_some());
	assert!(intent.archive.is_some() && intent.archive_control.is_some());
	assert_eq!(intent.operators.as_slice().len(), 1);
	Replay { derivation, commands }
}
