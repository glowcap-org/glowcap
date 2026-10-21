//! Application declarations, independent of shared Zig policy semantics. The
//! same body runs on Linux and in browser Wasm. Exact held roles are fixtures.
//! These tests do not claim runtime replacement or saved-reference support.
use Permission::*;
use core::num::NonZeroU64;
use rooms_application::{
	content::{
		permissions::{self, InvalidPolicy, Permission},
		session::{self, custody, requirements, workspace},
	},
	session::{
		checkpoint::commands,
		command::{Effect, Route},
		verbs::Method,
	},
};
use serde_json::{Value, json};
mod departure;
mod dispatch;
mod effects;
mod local;
mod operations;
mod records;
mod selection;

fn nz(value: u64) -> NonZeroU64 {
	NonZeroU64::new(value).unwrap()
}
fn key<K>(slot: u64, generation: u64) -> custody::FieldKey<K> {
	custody::FieldKey::new(nz(slot), nz(generation))
}

struct References;
// Different fixture role types make custody coordinates type checked, even
// though an adapter's transport may use one capability handle representation.
#[derive(PartialEq)]
struct Room(u64);
#[derive(PartialEq)]
struct Directory;
#[derive(PartialEq)]
struct Source(u64);
impl custody::References for References {
	type SessionAccess = Source;
	type SessionControl = ();
	type RoomAccess = Room;
	type DirectoryAccess = Directory;
	type DirectAccess = ();
	type DirectInbox = ();
	type ArchiveAccess = ();
	type Operator = ();
	type Operations = ();
	type IrcConnection = ();
	type Offer = ();
	type AcceptedAccess = ();
	type RoomControl = ();
	type ArchiveControl = ();
	type CreationReceipt = ();
	type PublicationLease = ();
	type RoomSeat = ();
	type RoomSubject = ();
	type RoomInbox = ();
	type RoomFiles = ();
	type Line = ();
	type DirectoryName = ();
	type DirectoryInbox = ();
	type SourceBlob = ();
}
fn terms() {
	let saved = session::Terms::new(&[ObserveWorkspace, InteractWorkspace, History, ReadFile]).unwrap();
	let observer = saved.apply(session::Preset::Observer).unwrap();
	assert_eq!(observer.permissions(), &[History, ReadFile, ObserveWorkspace]);
	assert_eq!(
		session::Group::Participation.matching(&observer),
		Some(session::Preset::Observer)
	);
	let admin = observer.apply(session::Preset::Administrator).unwrap();
	assert!(
		!admin.permissions().contains(&InteractWorkspace),
		"custody does not imply interaction"
	);
	assert_eq!(admin.apply(session::Preset::NoCustody).unwrap(), observer);
	assert_eq!(
		admin
			.apply(session::Preset::Collaborator)
			.unwrap()
			.apply(session::Preset::Observer)
			.unwrap(),
		admin
	);
	assert_eq!(
		session::Group::Custody.matching(&admin),
		Some(session::Preset::Administrator)
	);
	assert_eq!(
		saved.permissions(),
		&[History, ReadFile, ObserveWorkspace, InteractWorkspace]
	);
	let empty = session::Terms::new(&[]).unwrap();
	assert!(
		empty.apply(session::Preset::Administrator).is_err(),
		"a preset cannot add Observe implicitly"
	);
	assert!(empty.permissions().is_empty());
	let custom = session::Terms::new(&[ObserveWorkspace, ManageCustody]).unwrap();
	assert_eq!(session::Group::Custody.matching(&custom), None);
	let mut fields = alloc_fields();
	fields.sort_unstable();
	fields.dedup();
	assert_eq!(
		fields.len(),
		session::Group::ALL.iter().map(|g| g.fields().len()).sum::<usize>()
	);
	for &p in session::SUPPORTED {
		if let Some(required) = p.prerequisite() {
			assert_eq!(
				session::Terms::new(&[p]),
				Err(InvalidPolicy::Prerequisite {
					permission: p,
					required
				})
			);
		}
	}
	assert_eq!(session::Terms::new(&[Post]), Err(InvalidPolicy::Inapplicable(Post)));
	assert_eq!(
		session::Terms::new(&[History, History]),
		Err(InvalidPolicy::Duplicate(History))
	);
	for raw in [
		r#"["unknown"]"#,
		r#"["interactWorkspace"]"#,
		r#"["history","history"]"#,
		r#"["pause"]"#,
		r#"["observeWorkspace","interactWorkspace","replaceWorkspace","manageCustody","resolvePending","useOperations","history","readFile","readArchive","history"]"#,
	] {
		assert!(serde_json::from_str::<session::Terms>(raw).is_err(), "{raw}");
	}
	assert_eq!(
		serde_json::from_str::<session::Terms>(&serde_json::to_string(&admin).unwrap()).unwrap(),
		admin
	);
	for &p in Permission::ALL {
		assert_eq!(serde_json::to_value(p).unwrap(), p.name());
		assert_eq!(Permission::from_key(p.key()), Some(p));
		if let Some(required) = p.prerequisite() {
			assert!(permissions::validate(&[p], Permission::ALL).is_err());
			let mut values = vec![p, required];
			if let Some(parent) = required.prerequisite() {
				values.push(parent);
			}
			assert!(permissions::validate(&values, Permission::ALL).is_ok());
		}
	}
	assert_eq!(Permission::from_key(0), None);
	assert_eq!(Permission::from_key(u64::MAX), None);
	assert!(Permission::ALL.windows(2).all(|pair| pair[0].key() < pair[1].key()));
}
fn alloc_fields() -> Vec<u64> {
	session::Group::ALL
		.iter()
		.flat_map(|g| g.fields().iter().map(|p| p.key()))
		.collect()
}

fn mappings() {
	use requirements::{Conditional, Target};
	assert_eq!(
		requirements::method(Method::RoomBridgeForm).unwrap().workspace,
		&[ObserveWorkspace]
	);
	assert_eq!(
		requirements::method(Method::Command).unwrap().targets,
		&[Target::NestedCommand]
	);
	assert_eq!(
		requirements::method(Method::ResumeEffect).unwrap().targets,
		&[Target::PendingEffect]
	);
	assert_eq!(
		requirements::method(Method::ReadHistory).unwrap().targets,
		&[Target::ArchiveRead]
	);
	assert_eq!(
		requirements::method(Method::ArchivedAttachment).unwrap().workspace,
		&[History, ReadFile]
	);
	assert_eq!(
		requirements::method(Method::AdoptWorkspace).unwrap().conditional,
		&[Conditional::ImportsAuthority]
	);
	assert_eq!(Conditional::ImportsAuthority.workspace(), &[ManageCustody]);
	for method in [Method::Facet, Method::Revoke] {
		assert_eq!(requirements::method(method), None);
	}
	for &method in Method::ALL {
		assert_eq!(Method::parse(method.name()), Some(method));
		if let Some(requirement) = requirements::method(method) {
			assert!(requirement.workspace.iter().all(|p| session::SUPPORTED.contains(p)));
		}
	}
	for name in ["issueGrant", "setGrantPolicy", "revokeGrant", "unknown"] {
		assert_eq!(Method::parse(name), None);
	}
	for route in commands::Command::ALL
		.iter()
		.copied()
		.map(Route::Checkpoint)
		.chain(commands::results::Command::ALL.iter().copied().map(Route::Result))
		.chain(Effect::ALL.iter().copied().map(Route::Effect))
	{
		let name = match route {
			Route::Checkpoint(c) => serde_json::to_value(c).unwrap(),
			Route::Result(c) => serde_json::to_value(c).unwrap(),
			Route::Effect(c) => serde_json::to_value(c).unwrap(),
		};
		if route == Route::Result(commands::results::Command::LinkRoom) {
			assert_eq!(Route::parse(name.as_str().unwrap()), None);
			assert_eq!(requirements::command(route), None);
			continue;
		}
		assert_eq!(Route::parse(name.as_str().unwrap()), Some(route));
		let requirement = requirements::command(route).unwrap();
		if route == Route::Checkpoint(commands::Command::ClearWorkspace) {
			assert_eq!(requirement.workspace, &[ReplaceWorkspace, ManageCustody]);
		} else {
			assert!(requirement.workspace.contains(&InteractWorkspace));
		}
		assert!(requirement.workspace.iter().all(|p| session::SUPPORTED.contains(p)));
	}
	for command in [
		commands::Command::ReplaceOperationsCapabilities,
		commands::Command::ReplaceOperationsBundle,
		commands::Command::SelectArchive,
		commands::Command::DropRoomModerator,
		commands::Command::DropRoomManager,
	] {
		assert_eq!(
			requirements::command(Route::Checkpoint(command)).unwrap().workspace,
			&[InteractWorkspace, ManageCustody]
		);
	}
	for command in [
		commands::Command::LeaveDirectory,
		commands::Command::LeaveConversation,
		commands::Command::CloseDirect,
	] {
		assert!(
			requirements::command(Route::Checkpoint(command))
				.unwrap()
				.targets
				.is_empty(),
			"local release cannot require working upstream authority"
		);
	}
	assert_eq!(
		requirements::command(Route::Effect(Effect::KickRoomMember))
			.unwrap()
			.targets,
		&[Target::RoomModeration]
	);
	assert_eq!(
		requirements::command(Route::Effect(Effect::RevokeManagedRoomAuthority))
			.unwrap()
			.targets,
		&[Target::RoomRevoke]
	);
	assert_eq!(
		requirements::command(Route::Effect(Effect::Operations))
			.unwrap()
			.workspace,
		&[InteractWorkspace, UseOperations]
	);
}

fn fixture() -> Value {
	json!({
		"version": 1,
		"directories": [{"id": "directory", "access": key::<custody::DirectoryAccess>(1, 1), "home": true,
			"nick": "peer", "nickAllocation": "exact", "standing": null}],
		"conversations": [{"kind": "room", "id": "conversation", "directory": "directory", "name": "room",
			"access": key::<custody::RoomAccess>(1, 1), "control": null, "reconnect": "requested",
			"standing": null, "draft": "draft"}],
		"invitations": [], "active": "conversation", "standing": "", "ignored": [], "keepHistory": true,
		"connection": "relay", "archive": null, "archiveControl": null, "operators": [], "peering": []
	})
}
fn workspace() {
	let mut custody = custody::Custody::<References>::default();
	custody
		.insert_room_access(custody::Held {
			key: key(1, 1),
			reference: Room(7),
		})
		.unwrap();
	custody
		.insert_directory_access(custody::Held {
			key: key(1, 1),
			reference: Directory,
		})
		.unwrap();
	assert_eq!(custody.room_access(key(1, 1)).unwrap().reference.0, 7);
	assert!(
		custody.room_access(key(1, 2)).is_none(),
		"an old coordinate must not select a replacement generation"
	);
	assert_eq!(
		custody.insert_room_access(custody::Held {
			key: key(1, 2),
			reference: Room(8)
		}),
		Err(custody::Refusal::Duplicate)
	);
	let raw = fixture().to_string();
	let intent = workspace::Intent::decode(&raw).unwrap();
	assert_eq!(intent.validate(&custody), Ok(()));
	assert_eq!(
		intent.validate(&custody::Custody::<References>::default()),
		Err(workspace::InvalidIntent::Custody)
	);
	assert_eq!(
		workspace::Intent::decode(&serde_json::to_string(&intent).unwrap()).unwrap(),
		intent
	);
	for (field, value, expected) in [
		("active", json!("other"), workspace::InvalidIntent::Active),
		(
			"conversations",
			json!([fixture()["conversations"][0], fixture()["conversations"][0]]),
			workspace::InvalidIntent::Duplicate,
		),
	] {
		let mut v = fixture();
		v[field] = value;
		assert_eq!(
			workspace::Intent::decode(&v.to_string()).unwrap().validate(&custody),
			Err(expected)
		);
	}
	for (field, value) in [
		("version", json!(2)),
		("grant", json!("bearer")),
		("directories", json!([[]])),
	] {
		let mut v = fixture();
		v[field] = value;
		assert!(workspace::Intent::decode(&v.to_string()).is_err());
	}
	let mut old = fixture();
	old["conversations"][0]["link"] = json!("bearer");
	assert!(workspace::Intent::decode(&old.to_string()).is_err());
	let mut wrong_generation = fixture();
	wrong_generation["conversations"][0]["access"] = json!(key::<custody::RoomAccess>(1, 2));
	assert_eq!(
		workspace::Intent::decode(&wrong_generation.to_string())
			.unwrap()
			.validate(&custody),
		Err(workspace::InvalidIntent::Custody)
	);
	let mut moderation = fixture();
	moderation["conversations"][0]["moderator"] = json!(key::<custody::RoomAccess>(1, 1));
	assert!(
		workspace::Intent::decode(&moderation.to_string())
			.unwrap()
			.validate(&custody)
			.is_ok()
	);
	moderation["conversations"][0]["moderator"] = json!(key::<custody::RoomAccess>(1, 2));
	assert_eq!(
		workspace::Intent::decode(&moderation.to_string())
			.unwrap()
			.validate(&custody),
		Err(workspace::InvalidIntent::Custody)
	);
	let literal = raw.replace("\"draft\":\"draft\"", "\"draft\":\"\\ud800\"");
	let decoded = workspace::Intent::decode(&literal).unwrap();
	assert_eq!(
		workspace::Intent::decode(&serde_json::to_string(&decoded).unwrap()).unwrap(),
		decoded
	);
	let large = key::<custody::RoomAccess>(u64::MAX, u64::MAX);
	assert_eq!(
		serde_json::from_str::<custody::FieldKey<custody::RoomAccess>>(&serde_json::to_string(&large).unwrap())
			.unwrap(),
		large
	);
	for raw in [
		"1",
		r#""00000000000000000000000000000001""#,
		r#""00000000000000010000000000000000""#,
		r#""FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF""#,
	] {
		assert!(serde_json::from_str::<custody::FieldKey<custody::RoomAccess>>(raw).is_err());
	}
	assert_eq!(custody.fields().count(), 2);
	assert!(custody.remove_room_access(key(1, 2)).is_none());
	let original = custody.remove_room_access(key(1, 1)).unwrap();
	let receipt = custody::EffectReceipt::<References> {
		introduction: None,
		adopted: false,
		outgoing: None,
		operation: rooms_application::session::state::OperationId::new("op".into()).unwrap(),
		canonical_intent: rooms_application::fields::Text::new("canonical intent".into()).unwrap(),
		resource_generation: nz(1),
		source: custody::Held {
			key: key(1, 1),
			reference: Source(3),
		},
		targets: rooms_application::fields::List::new(vec![custody::RetainedField::RoomAccess(original)]).unwrap(),
		outcome: custody::Outcome::Unresolved,
	};
	assert_eq!(intent.validate(&custody), Err(workspace::InvalidIntent::Custody));
	custody
		.insert_room_access(custody::Held {
			key: key(1, 2),
			reference: Room(8),
		})
		.unwrap();
	assert_eq!(intent.validate(&custody), Err(workspace::InvalidIntent::Custody));
	assert_eq!(receipt.source.reference.0, 3);
	let custody::RetainedField::RoomAccess(original) = &receipt.targets.as_slice()[0] else {
		panic!("original room target")
	};
	assert_eq!(original.reference.0, 7);
	assert_eq!(custody.room_access(key(1, 2)).unwrap().reference.0, 8);
	assert!(matches!(receipt.outcome, custody::Outcome::Unresolved));
	let mut released = fixture();
	released["conversations"][0]["access"] = Value::Null;
	released["conversations"][0]["reconnect"] = json!("manual");
	assert_eq!(
		workspace::Intent::decode(&released.to_string())
			.unwrap()
			.validate(&custody),
		Ok(())
	);
	let mut homes = fixture();
	let mut second = homes["directories"][0].clone();
	second["id"] = json!("second");
	homes["directories"].as_array_mut().unwrap().push(second);
	assert_eq!(
		workspace::Intent::decode(&homes.to_string())
			.unwrap()
			.validate(&custody),
		Err(workspace::InvalidIntent::Home)
	);
	let oversized = " ".repeat(custody::MAX_AUTHORITY_BYTES + 1);
	assert!(matches!(
		workspace::Intent::decode(&oversized),
		Err(workspace::DecodeError::Capacity)
	));
	let mut full = custody::Custody::<References>::default();
	for i in 1..=custody::MAX_FIELDS_PER_ROLE as u64 {
		full.insert_room_access(custody::Held {
			key: key(i, 1),
			reference: Room(i),
		})
		.unwrap();
	}
	assert_eq!(
		full.insert_room_access(custody::Held {
			key: key(custody::MAX_FIELDS_PER_ROLE as u64 + 1, 1),
			reference: Room(0)
		}),
		Err(custody::Refusal::Capacity)
	);
}
pub fn run() {
	for &role in custody::Role::ALL {
		let coordinate = custody::Coordinate { role, key: key(1, 1) };
		assert_eq!(
			custody::Coordinate::decode(&serde_json::to_string(&coordinate).unwrap()).unwrap(),
			coordinate
		);
		assert!(custody::Coordinate::decode(&json!([role, coordinate.key]).to_string()).is_err());
	}
	terms();
	mappings();
	workspace();
	records::run();
	effects::run();
	dispatch::run();
	local::run();
	operations::run();
	selection::run();
	departure::run();
}
