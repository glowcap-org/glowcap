//! Automatic gestures fence their selected rows, not unrelated supervisor work.
//! Workspace-wide commands retain a whole-intent fence. These are scalar views;
//! actual admission and retained authority remain in the managed owner.
use crate::session::{
	checkpoint::commands::Command,
	command::{Effect, Route},
};
use alloc::string::String;
use serde_json::Value;

fn row<'a>(intent: &'a Value, collection: &str, id: &str) -> Option<&'a Value> {
	intent[collection].as_array()?.iter().find(|row| row["id"] == id)
}
fn same_row(before: &Value, after: &Value, collection: &str, id: Option<&String>) -> bool {
	let Some(id) = id else { return false };
	let Some(original) = row(before, collection, id) else {
		return false;
	};
	row(after, collection, id) == Some(original)
}
/// A conversation's receiving callback and its posted-line receipts are written
/// by supervisors while a gesture is being admitted, and its draft by the
/// composer. None of them changes which authority a gesture exercises, so a
/// conflict caused by one of them re-prepares instead of refusing the gesture.
/// A draft save fences the draft itself, so a competing edit from another
/// viewer is refused rather than overwritten.
const SUPERVISED: [&str; 2] = ["inbox", "lines"];
const CONVERSATION_STATE: [&str; 3] = ["inbox", "lines", "draft"];
fn same_conversation(before: &Value, after: &Value, id: Option<&String>) -> bool {
	same_conversation_except(before, after, id, &CONVERSATION_STATE)
}
fn same_conversation_except(before: &Value, after: &Value, id: Option<&String>, ignored: &[&str]) -> bool {
	let Some(id) = id else { return false };
	let (Some(Value::Object(before)), Some(Value::Object(after))) =
		(row(before, "conversations", id), row(after, "conversations", id))
	else {
		return false;
	};
	let kept = |key: &&String| !ignored.contains(&key.as_str());
	before
		.keys()
		.chain(after.keys())
		.filter(kept)
		.all(|key| before.get(key) == after.get(key))
}
/// Selecting a conversation exercises no authority. The exact row must still be
/// the conversation the person chose; membership churn underneath it is not a
/// reason to refuse.
fn same_conversation_identity(before: &Value, after: &Value, id: Option<&String>) -> bool {
	let Some(id) = id else { return false };
	let (Some(before), Some(after)) = (row(before, "conversations", id), row(after, "conversations", id)) else {
		return false;
	};
	["id", "kind", "directory", "source"]
		.into_iter()
		.all(|key| before[key] == after[key])
}
/// Moderator issuance, unregistration and policy change select only the room's
/// held manager (`RoomTarget::Control` in dispatch). Membership supervision
/// rewrites the seat, topic and files whenever it realizes the room again, as
/// it does after the entry link rotates. That work leaves the manager alone, so
/// it re-prepares rather than refusing the gesture.
fn same_room_manager(before: &Value, after: &Value, id: Option<&String>) -> bool {
	let Some(id) = id else { return false };
	let (Some(before), Some(after)) = (row(before, "conversations", id), row(after, "conversations", id)) else {
		return false;
	};
	!before["control"].is_null()
		&& ["id", "kind", "directory", "control"]
			.into_iter()
			.all(|key| before[key] == after[key])
}
pub fn same_directory_contact(before: &Value, after: &Value) -> bool {
	["id", "access", "source", "name", "inbox"]
		.into_iter()
		.all(|key| before[key] == after[key])
}
fn same_operations(before: &Value, after: &Value, args: &[String]) -> bool {
	let Some(coordinate) = args.first().and_then(|raw| serde_json::from_str::<Value>(raw).ok()) else {
		return false;
	};
	let Some(kind) = args.get(1) else { return false };
	let Some(original) = operation_row(before, &coordinate, kind) else {
		return false;
	};
	operation_row(after, &coordinate, kind) == Some(original)
}
fn operation_row<'a>(intent: &'a Value, coordinate: &Value, kind: &str) -> Option<&'a Value> {
	intent["operations"]
		.as_array()?
		.iter()
		.find(|row| row["handle"] == *coordinate && row["kind"] == kind)
}
pub fn unchanged(name: &str, args: &[String], before: &Value, after: &Value) -> bool {
	use Command::*;
	let Some(route) = Route::parse(name) else { return false };
	match route {
		Route::Effect(Effect::Operations) => same_operations(before, after, args),
		Route::Effect(Effect::Operator) => {
			let Some(key) = args.first().and_then(|raw| serde_json::from_str::<Value>(raw).ok()) else {
				return false;
			};
			[before, after]
				.into_iter()
				.all(|intent| intent["operators"].as_array().is_some_and(|rows| rows.contains(&key)))
		}
		Route::Checkpoint(StartDirect) => {
			let Some(id) = args.first() else { return false };
			let (Some(original), Some(current)) = (row(before, "directories", id), row(after, "directories", id))
			else {
				return false;
			};
			same_directory_contact(original, current)
		}
		Route::Checkpoint(Select) => same_conversation_identity(before, after, args.first()),
		Route::Checkpoint(SetDraft) => same_conversation_except(before, after, args.first(), &SUPERVISED),
		Route::Checkpoint(
			CloseDirect | LeaveConversation | SetRoomStanding | DropRoomModerator | DropRoomManager
			| SubmitRoomBridgeForm,
		)
		| Route::Effect(
			Effect::Say
			| Effect::SetRoomTopic
			| Effect::SetRoomAway
			| Effect::RetireRoomMembership
			| Effect::KickRoomMember
			| Effect::DirectReady
			| Effect::OfferDirectInbox
			| Effect::EditLine
			| Effect::WithdrawLine
			| Effect::RevokeManagedRoomAuthority,
		)
		| Route::Result(crate::session::checkpoint::commands::results::Command::EnsureRoomLink) => {
			same_conversation(before, after, args.first())
		}
		Route::Effect(Effect::IssueRoomModerator | Effect::UnregisterManagedRoom | Effect::SetManagedRoomPolicy) => {
			same_room_manager(before, after, args.first())
		}
		Route::Checkpoint(
			JoinDirectory | SetDirectoryNick | ChooseDirectoryNickname | SetDirectoryStanding | JoinRoom,
		) => {
			let collection = if matches!(route, Route::Checkpoint(JoinRoom)) {
				"conversations"
			} else {
				"directories"
			};
			same_row(before, after, collection, args.first())
		}
		Route::Effect(Effect::EnterRoom)
		| Route::Result(crate::session::checkpoint::commands::results::Command::OpenManagedRoom) => {
			same_row(before, after, "directories", args.first())
		}
		Route::Checkpoint(AcceptInvitation | DismissInvitation) => same_row(before, after, "invitations", args.first()),
		Route::Effect(Effect::OfferRoom) => {
			same_conversation(before, after, args.first()) && same_conversation(before, after, args.get(1))
		}
		Route::Checkpoint(SetEffectiveStanding) => {
			let Some(id) = args.first() else { return false };
			let Some(original) = row(before, "conversations", id) else {
				return false;
			};
			if !same_conversation(before, after, Some(id)) {
				return false;
			}
			// An explicit room setting, including empty, owns this write. Facts
			// inherited from other scopes cannot refuse a change to that setting.
			if !original["standing"].is_null() {
				return true;
			}
			let Some(directory) = original["directory"].as_str() else {
				return false;
			};
			let (Some(original), Some(current)) = (
				row(before, "directories", directory),
				row(after, "directories", directory),
			) else {
				return false;
			};
			if !["id", "access", "source", "standing"]
				.into_iter()
				.all(|key| original[key] == current[key])
			{
				return false;
			}
			!original["standing"].is_null() || before["standing"] == after["standing"]
		}
		// Other commands replace workspace-wide configuration or consume several
		// selections. Keep their complete original intent rather than guessing a
		// partial footprint from argument strings.
		_ => before == after,
	}
}

#[cfg(test)]
mod tests {
	use super::unchanged;
	use alloc::{string::String, vec};
	use serde_json::{Value, json};

	fn workspace(row: Value) -> Value {
		json!({ "conversations": [row], "directories": [], "invitations": [] })
	}
	fn direct() -> Value {
		json!({
			"kind": "direct", "id": "ada", "directory": "home", "peer": "ada",
			"source": [1, 1], "access": [2, 1], "closed": false, "draft": ""
		})
	}
	fn with(mut row: Value, key: &str, value: Value) -> Value {
		row[key] = value;
		row
	}
	fn args() -> vec::Vec<String> {
		vec!["ada".into()]
	}

	#[test]
	fn room_manager_gestures_survive_realization_but_not_a_new_manager() {
		let room = json!({
			"kind": "room", "id": "lobby", "directory": "home", "name": "lobby",
			"access": "k1g1", "seat": "k2g1", "topic": "k3g1", "files": "k4g1",
			"control": "k5g1", "reconnect": "requested", "standing": null, "draft": ""
		});
		let before = workspace(room.clone());
		let realized = with(
			with(with(room.clone(), "seat", json!("k6g1")), "topic", json!("k7g1")),
			"files",
			json!("k8g1"),
		);
		let relinked = with(realized, "access", json!("k9g1"));
		let args = vec![String::from("lobby")];
		for name in ["issueRoomModerator", "unregisterManagedRoom", "setManagedRoomPolicy"] {
			assert!(unchanged(name, &args, &before, &workspace(relinked.clone())), "{name}");
			assert!(!unchanged(
				name,
				&args,
				&before,
				&workspace(with(room.clone(), "control", json!("k5g2")))
			));
			assert!(!unchanged(
				name,
				&args,
				&workspace(with(room.clone(), "control", Value::Null)),
				&before
			));
		}
		// Revocation names the authority it ends, so it keeps the whole room fence.
		assert!(!unchanged(
			"revokeManagedRoomAuthority",
			&args,
			&before,
			&workspace(relinked)
		));
	}

	#[test]
	fn operations_fence_exact_custody_across_supervisor_churn() {
		let before = json!({ "operations": [{"kind":"ircGateway", "handle":{"role":"operations", "key":"original"}}],
			"operators":["operator"], "conversations":[] });
		let args = vec![r#"{"role":"operations","key":"original"}"#.into(), "ircGateway".into()];
		let mut after = before.clone();
		after["conversations"] = json!([{"id":"room", "seat":"fresh", "draft":"typing"}]);
		assert!(unchanged("operations", &args, &before, &after));
		assert!(unchanged("operator", &[r#""operator""#.into()], &before, &after));
		after["operations"][0]["handle"]["key"] = json!("replacement");
		assert!(!unchanged("operations", &args, &before, &after));
		after["operators"] = json!([]);
		assert!(!unchanged("operator", &[r#""operator""#.into()], &before, &after));
	}

	#[test]
	fn supervisor_state_never_refuses_a_conversation_gesture() {
		let before = workspace(direct());
		let installed = with(direct(), "inbox", json!([3, 1]));
		let installed = with(installed, "lines", json!([{ "id": 7, "handle": [4, 1] }]));
		for name in ["select", "setDraft", "say", "editLine", "closeDirect"] {
			assert!(
				unchanged(name, &args(), &before, &workspace(installed.clone())),
				"{name}"
			);
		}
		let typed = workspace(with(installed, "draft", json!("typing")));
		for name in ["select", "say", "editLine", "closeDirect"] {
			assert!(unchanged(name, &args(), &before, &typed), "{name}");
		}
		assert!(
			!unchanged("setDraft", &args(), &before, &typed),
			"a competing draft is refused"
		);
	}

	#[test]
	fn effective_standing_fences_only_the_owner_it_writes() {
		let before = json!({
			"standing": "workspace",
			"directories": [{"id":"home", "standing":"directory", "name":[9,1]}],
			"conversations": [{"kind":"room", "id":"ada", "directory":"home", "standing":""}]
		});
		let mut after = before.clone();
		after["standing"] = json!("changed elsewhere");
		after["directories"][0]["name"] = json!([9, 2]);
		assert!(unchanged("setEffectiveStanding", &args(), &before, &after));
		after["conversations"][0]["standing"] = json!("competing room choice");
		assert!(!unchanged("setEffectiveStanding", &args(), &before, &after));

		let mut before = before;
		before["conversations"][0]["standing"] = Value::Null;
		let mut after = before.clone();
		after["directories"][0]["name"] = json!([9, 2]);
		assert!(unchanged("setEffectiveStanding", &args(), &before, &after));
		after["directories"][0]["standing"] = json!("competing directory choice");
		assert!(!unchanged("setEffectiveStanding", &args(), &before, &after));

		before["directories"][0]["standing"] = Value::Null;
		let mut after = before.clone();
		after["standing"] = json!("competing workspace choice");
		assert!(!unchanged("setEffectiveStanding", &args(), &before, &after));
	}

	#[test]
	fn selection_ignores_route_replacement_but_authority_does_not() {
		let before = workspace(direct());
		let after = workspace(with(direct(), "access", json!([2, 2])));
		assert!(unchanged("select", &args(), &before, &after));
		assert!(!unchanged("setDraft", &args(), &before, &after));
		assert!(!unchanged("say", &args(), &before, &after));
		assert!(!unchanged("closeDirect", &args(), &before, &after));
	}

	#[test]
	fn a_replaced_or_retired_conversation_refuses_every_gesture() {
		let before = workspace(direct());
		let replaced = workspace(with(direct(), "source", json!([1, 2])));
		let retired = json!({ "conversations": [], "directories": [], "invitations": [] });
		for name in ["select", "setDraft", "say"] {
			assert!(!unchanged(name, &args(), &before, &replaced), "{name}");
			assert!(!unchanged(name, &args(), &before, &retired), "{name}");
		}
	}
}
