//! Run the same interruption and cold-recovery contract for each dispatch role.
use super::*;
use rooms_application::fields::Text;

#[derive(Clone)]
pub(super) struct Case {
	pub name: &'static str,
	pub args: Vec<String>,
	pub verb: &'static str,
	pub forwarded: Vec<rooms_application::session::effect::Argument>,
	pub role: custody::Role,
	pub policy: Option<rooms_application::room::policy::RoomPolicy>,
}
impl Case {
	pub fn away() -> Self {
		Self {
			name: "setRoomAway",
			args: vec!["conversation".into(), "away".into()],
			verb: "away",
			forwarded: vec!["away".into()],
			role: custody::Role::RoomSeat,
			policy: None,
		}
	}
	pub fn topic() -> Self {
		Self {
			name: "setRoomTopic",
			args: vec!["conversation".into(), "topic".into()],
			verb: "setTopic",
			forwarded: vec!["topic".into()],
			role: custody::Role::RoomTopic,
			policy: None,
		}
	}
	pub fn line(withdraw: bool) -> Self {
		Self {
			name: if withdraw { "withdrawLine" } else { "editLine" },
			args: if withdraw {
				vec!["conversation".into(), "23".into()]
			} else {
				vec!["conversation".into(), "23".into(), "edited".into()]
			},
			verb: if withdraw { "withdraw" } else { "edit" },
			forwarded: if withdraw { vec![] } else { vec!["edited".into()] },
			role: custody::Role::Line,
			policy: None,
		}
	}
	pub fn operator() -> Self {
		Self {
			name: "operator",
			args: vec![
				serde_json::to_string(&key::<custody::Operator>()).unwrap(),
				"clearTrouble".into(),
			],
			verb: "clearOperatorTrouble",
			forwarded: vec![],
			role: custody::Role::Operator,
			policy: None,
		}
	}
	pub fn operations() -> Self {
		let coordinate = custody::Coordinate {
			role: custody::Role::Operations,
			key: key(),
		};
		Self {
			name: "operations",
			args: vec![
				serde_json::to_string(&coordinate).unwrap(),
				"listeners".into(),
				"down".into(),
				"7".into(),
			],
			verb: "down",
			forwarded: vec![rooms_application::session::effect::Argument::Integer(7)],
			role: custody::Role::Operations,
			policy: None,
		}
	}
	pub fn other_operations() -> Vec<Self> {
		use rooms_application::session::effect::Argument as Data;
		[
			("listeners", "up", vec!["tcp".into()], vec![Data::from("tcp")]),
			(
				"listeners",
				"up",
				vec!["tcp".into(), r#"{"port":9000}"#.into()],
				vec![
					Data::from("tcp"),
					Data::List(vec![Data::List(vec![Data::from("port"), Data::Integer(9000)])]),
				],
			),
			(
				"ircGateway",
				"openConnection",
				vec!["{}".into()],
				vec![Data::from("{}")],
			),
			("ircConnection", "addLease", vec!["{}".into()], vec![Data::from("{}")]),
			(
				"ircConnection",
				"removeLease",
				vec!["lease".into()],
				vec![Data::from("lease")],
			),
			("ircConnection", "closeConnection", vec![], vec![]),
		]
		.into_iter()
		.map(|(kind, verb, rest, forwarded)| {
			let role = if kind == "ircConnection" {
				custody::Role::IrcConnection
			} else {
				custody::Role::Operations
			};
			let coordinate = custody::Coordinate { role, key: key() };
			let mut args = vec![serde_json::to_string(&coordinate).unwrap(), kind.into(), verb.into()];
			args.extend(rest);
			Self {
				name: "operations",
				args,
				verb,
				forwarded,
				role,
				policy: None,
			}
		})
		.collect()
	}
	pub fn kick() -> Self {
		Self {
			name: "kickRoomMember",
			args: vec!["conversation".into(), "member".into()],
			verb: "kick",
			forwarded: vec!["member".into()],
			role: custody::Role::RoomAccess,
			policy: None,
		}
	}
	pub fn revoke(kind: &'static str) -> Self {
		Self {
			name: "revokeManagedRoomAuthority",
			args: vec![
				"conversation".into(),
				kind.into(),
				serde_json::to_string(&custody::FieldKey::<custody::RoomAccess>::new(
					NonZeroU64::new(3).unwrap(),
					NonZeroU64::new(1).unwrap(),
				))
				.unwrap(),
			],
			verb: if kind == "room" {
				"revokeRoomLink"
			} else {
				"revokeSteward"
			},
			forwarded: vec!["exact-token".into()],
			role: custody::Role::RoomControl,
			policy: None,
		}
	}
	pub fn policy(unregister: bool) -> Self {
		use rooms_application::room::policy::RoomPolicy;
		Self {
			name: if unregister {
				"unregisterManagedRoom"
			} else {
				"setManagedRoomPolicy"
			},
			args: if unregister {
				vec!["conversation".into()]
			} else {
				vec![
					"conversation".into(),
					"listed".into(),
					"open".into(),
					"moderated".into(),
				]
			},
			verb: if unregister { "unregisterRoom" } else { "setRoomPolicy" },
			forwarded: if unregister {
				vec![]
			} else {
				vec!["listed".into(), "open".into(), "moderated".into(), "room".into()]
			},
			role: custody::Role::RoomControl,
			policy: Some(if unregister {
				RoomPolicy::Private
			} else {
				RoomPolicy::Moderated
			}),
		}
	}
	pub fn reply(&self) -> Argument {
		if self.name == "operations" {
			match self.verb {
				"up" => {
					return Argument::List(vec![
						"tcp".into(),
						"listener".into(),
						"".into(),
						"".into(),
						Argument::List(vec![]),
						"".into(),
						Argument::Integer(7),
						"tcp://127.0.0.1:9000".into(),
						true.into(),
					]);
				}
				"openConnection" | "addLease" | "removeLease" => return "operation-result".into(),
				_ => {}
			}
		}
		match self.policy {
			None => Argument::Void,
			Some(policy) => {
				let [visibility, entry, speaking] = policy.modes();
				Argument::List(vec![
					"returned".into(),
					visibility.into(),
					entry.into(),
					speaking.into(),
				])
			}
		}
	}
	pub fn retained_result(&self) -> &'static str {
		if self.name == "operations" {
			match self.verb {
				"up" => {
					return r#"{"transport":"tcp","description":"listener","reference":"","referenceName":"","takes":[],"unavailable":"","id":7,"locator":"tcp://127.0.0.1:9000","serving":true}"#;
				}
				"openConnection" | "addLease" | "removeLease" => return r#""operation-result""#,
				_ => {}
			}
		}
		use rooms_application::room::policy::RoomPolicy;
		match self.policy {
			None => "null",
			Some(RoomPolicy::Private) => {
				r#"{"name":"returned","policy":{"visibility":"secret","entry":"invite-only","speaking":"moderated"}}"#
			}
			Some(RoomPolicy::Moderated) => {
				r#"{"name":"returned","policy":{"visibility":"listed","entry":"open","speaking":"moderated"}}"#
			}
			_ => panic!("unused result fixture"),
		}
	}
	pub fn coordinate(&self, slot: u64) -> custody::Coordinate {
		custody::Coordinate {
			role: self.role,
			key: custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap()),
		}
	}
	pub fn workspace(&self, slot: u64) -> Intent {
		let mut intent = Intent::empty();
		let coordinate = self.coordinate(slot).key;
		if self.role == custody::Role::Operator {
			intent.operators =
				List::new(vec![custody::FieldKey::new(coordinate.slot(), coordinate.generation())]).unwrap();
		} else if matches!(self.role, custody::Role::Operations | custody::Role::IrcConnection) {
			intent.operations = List::new(vec![rooms_application::content::session::workspace::Operations {
				connection: (self.role == custody::Role::IrcConnection).then(|| {
					rooms_application::content::session::workspace::ConnectionSelection {
						operation: Text::new("fixture".into()).unwrap(),
						gateway: custody::Coordinate {
							role: custody::Role::Operations,
							key: self.coordinate(slot).key,
						},
						id: Text::new("fixture".into()).unwrap(),
					}
				}),
				kind: serde_json::from_value(serde_json::Value::String(self.args[1].clone())).unwrap(),
				handle: self.coordinate(slot),
			}])
			.unwrap();
		} else {
			let key = serde_json::to_value(coordinate).unwrap();
			let entry =
				custody::FieldKey::<custody::RoomAccess>::new(NonZeroU64::new(3).unwrap(), NonZeroU64::new(1).unwrap());
			intent.directories = serde_json::from_value(serde_json::json!([{
				"id": "directory", "access": super::key::<custody::DirectoryAccess>(), "home": true,
				"nick": "peer", "nickAllocation": "exact", "standing": null
			}]))
			.unwrap();
			intent.conversations = serde_json::from_str(
				&serde_json::json!([{
					"kind": "room", "id": "conversation", "directory": "directory", "name": "room",
					"access": if self.role == custody::Role::RoomAccess || self.name == "revokeManagedRoomAuthority" { Some(&entry) } else { None },
					"moderator": if self.name == "revokeManagedRoomAuthority" && self.args[1] == "steward" { Some(serde_json::to_value(entry).unwrap()) } else if self.role == custody::Role::RoomAccess { Some(key.clone()) } else { None },
					"control": if self.role == custody::Role::RoomControl { Some(&key) } else { None },
					"topic": if self.role == custody::Role::RoomTopic { Some(&key) } else { None },
					"seat": if self.role == custody::Role::RoomSeat { Some(&key) } else { None },
					"lines": if self.role == custody::Role::Line { serde_json::json!([{ "id": 23, "handle": key }]) } else { serde_json::json!([]) },
					"reconnect": if self.role == custody::Role::RoomAccess || self.name == "revokeManagedRoomAuthority" { "requested" } else { "manual" }, "standing": null, "draft": ""
				}])
				.to_string(),
			)
			.unwrap();
		}
		intent
	}
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn away_retains_exact_live_seat_through_interruption_and_restart() {
	run(Case::away()).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn operations_retains_exact_interface_and_typed_arguments_through_interruption_and_restart() {
	run(Case::operations()).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn listener_and_irc_mutations_retain_exact_interfaces_typed_data_and_results_through_restart() {
	for case in Case::other_operations() {
		run(case).await;
	}
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn topic_retains_exact_live_target_through_interruption_and_restart() {
	run(Case::topic()).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn edit_retains_exact_live_line_through_interruption_and_restart() {
	run(Case::line(false)).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn withdrawal_retains_exact_live_line_through_interruption_and_restart() {
	run(Case::line(true)).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn moderation_retains_exact_target_through_interruption_and_restart() {
	run(Case::kick()).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn room_revocation_retains_exact_target_through_interruption_and_restart() {
	run(Case::revoke("room")).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn steward_revocation_retains_exact_target_through_interruption_and_restart() {
	run(Case::revoke("steward")).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn policy_change_retains_exact_target_and_typed_result_through_restart() {
	run(Case::policy(false)).await;
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn unregistration_retains_exact_target_and_typed_result_through_restart() {
	run(Case::policy(true)).await;
}
