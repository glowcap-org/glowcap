use crate::arguments::Arg;
use rooms_application::{
	grants::Access,
	session::command::{Refusal, Request, Route},
};
use serde_json::Value;
fn fixture() -> Value {
	serde_json::from_str(include_str!("../fixtures/session-command-admission.json")).unwrap()
}
fn arguments(row: &Value) -> Vec<Arg> {
	row["args"]
		.as_array()
		.unwrap()
		.iter()
		.map(|v| {
			if let Some(integer) = v["integer"].as_str() {
				Arg::Integer(integer.parse().unwrap())
			} else if let Some(float) = v["float"].as_f64() {
				Arg::Float(float)
			} else if let Some(text) = v["text"].as_str() {
				Arg::Text(text.repeat(v["repeat"].as_u64().unwrap_or(1) as usize))
			} else {
				Arg::Null
			}
		})
		.collect()
}
pub fn run() {
	let fixture = fixture();
	for row in fixture["rows"].as_array().unwrap() {
		let args = arguments(row);
		let access = match row["access"].as_str().unwrap() {
			"admin" => Access::Admin,
			"interact" => Access::Interact,
			"observe" => Access::Observe,
			_ => Access::None,
		};
		let result = Request::read(access, &args);
		assert_eq!(
			result.is_ok(),
			row["accepted"].as_bool().unwrap(),
			"{}: {:?}",
			row["name"],
			result.as_ref().err()
		);
		if let Ok(request) = result {
			assert_eq!(request.material_bytes(), row["bytes"].as_u64().unwrap() as usize);
			assert_eq!(request.args().len(), args.len() - 3);
			assert_eq!(
				request.id(),
				if row["name"] == "id-limit" {
					"😀".repeat(64)
				} else if row["name"].as_str().unwrap().starts_with("revision-") {
					"op".into()
				} else {
					"operation".into()
				}
			);
		}
	}
	// Every checkpoint command in the dispatch catalog must be admitted.
	for expected in rooms_application::session::checkpoint::commands::Command::ALL {
		let value = serde_json::to_value(expected).unwrap();
		let name = value.as_str().unwrap();
		let args = [Arg::Text("op".into()), Arg::Integer(0), Arg::Text(name.into())];
		let request = Request::read(Access::Admin, &args).unwrap();
		let Route::Checkpoint(command) = request.route() else {
			panic!("checkpoint route")
		};
		assert_eq!(command, *expected);
	}
	for name in [
		"openManagedRoom",
		"ensureRoomLink",
		"takeRoomManager",
		"takeRoomModerator",
		"recoverRoomManager",
	] {
		let args = [Arg::Text("op".into()), Arg::Integer(0), Arg::Text(name.into())];
		assert!(matches!(
			Request::read(Access::Interact, &args).unwrap().route(),
			Route::Result(_)
		));
	}
	for name in [
		"offerRoom",
		"setRoomSubject",
		"kickRoomMember",
		"say",
		"editLine",
		"withdrawLine",
		"operator",
		"revokeManagedRoomAuthority",
		"unregisterManagedRoom",
		"setManagedRoomPolicy",
		"operations",
	] {
		let args = [Arg::Text("op".into()), Arg::Integer(0), Arg::Text(name.into())];
		assert!(matches!(
			Request::read(Access::Interact, &args).unwrap().route(),
			Route::Effect(_)
		));
	}
	for name in ["linkRoom", "unknown"] {
		let args = [Arg::Text("op".into()), Arg::Integer(0), Arg::Text(name.into())];
		assert!(matches!(Request::read(Access::Admin, &args), Err(Refusal::Unknown)));
	}
	let drops = std::rc::Rc::new(std::cell::Cell::new(0));
	let args = [
		Arg::Text("op".into()),
		Arg::Integer(0),
		Arg::Text("say".into()),
		Arg::List(vec![Arg::Capability(drops.clone())]),
	];
	assert!(matches!(Request::read(Access::Admin, &args), Err(Refusal::Arguments)));
	assert_eq!(drops.get(), 0);
	drop(args);
	assert_eq!(drops.get(), 1);
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[test]
fn binding_admission_preserves_integer_kind_and_borrowed_arguments() {
	use glowcap::Argument;
	for (revision, accepted) in [
		(Argument::Integer(0), true),
		(
			Argument::BigInteger {
				negative: false,
				digits: "9007199254740991".into(),
			},
			true,
		),
		(
			Argument::BigInteger {
				negative: false,
				digits: "9007199254740992".into(),
			},
			false,
		),
		(Argument::Integer(-1), false),
		(Argument::Float(0.0), false),
	] {
		let args = [
			Argument::String("operation".into()),
			revision,
			Argument::String("say".into()),
			Argument::String("room".into()),
			Argument::String("hello".into()),
		];
		let views: Vec<_> = rooms_glowcap::values(&args).collect();
		let admitted = Request::read(Access::Interact, &views);
		assert_eq!(admitted.is_ok(), accepted);
		if let Ok(request) = admitted {
			let text = request.args().nth(1).unwrap();
			assert!(core::ptr::eq(text.as_ptr(), args[4].as_str().unwrap().as_ptr()));
		}
	}
}
