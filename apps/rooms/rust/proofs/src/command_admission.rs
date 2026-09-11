use crate::arguments::Arg;
use rooms_application::{
	grants::Access,
	session::{
		checkpoint::{commands, Checkpoint, Routes},
		command::{Refusal, Request, Route},
	},
	text::DocumentText,
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
struct CapturedRoutes<'a>(&'a Value);
impl Routes for CapturedRoutes<'_> {
	fn locator_authority(&self, raw: &str) -> Option<String> {
		self.0["locatorAuthorities"][raw].as_str().map(str::to_owned)
	}
	fn sturdyref_authority(&self, raw: &str) -> Option<String> {
		self.0["sturdyrefAuthorities"][raw].as_str().map(str::to_owned)
	}
}
fn handed(fixture: &Value, routes: &impl Routes) {
	for row in fixture["handed"].as_array().unwrap() {
		let before = Checkpoint::decode(row["before"].as_str().unwrap(), routes).unwrap();
		let original = before.encode_for(Access::Admin).unwrap();
		let invitation = row["invitation"].as_str().unwrap().into();
		let args: [DocumentText; 2] = serde_json::from_value(row["args"].clone()).unwrap();
		let result = commands::accept_handed(&before, &invitation, &args, routes);
		assert_eq!(
			result.is_ok(),
			row["after"].is_string(),
			"{}: {:?}",
			row["name"],
			result.as_ref().err()
		);
		if let Ok(after) = result {
			assert_eq!(
				after.encode_for(Access::Admin).unwrap(),
				row["after"].as_str().unwrap(),
				"{}",
				row["name"]
			);
		}
		assert_eq!(
			before.encode_for(Access::Admin).unwrap(),
			original,
			"failed or successful candidate changed source"
		);
		let different = ["different-handed-id".into(), args[1].clone()];
		assert!(commands::accept_handed(&before, &invitation, &different, routes).is_err());
	}
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
	// Route every concrete pure command captured by the existing policy proof.
	let commands: Value = serde_json::from_str(include_str!("../fixtures/session-commands.json")).unwrap();
	for row in commands["rows"].as_array().unwrap() {
		let name = row["command"].as_str().unwrap();
		let args = [Arg::Text("op".into()), Arg::Integer(0), Arg::Text(name.into())];
		let request = Request::read(Access::Admin, &args).unwrap();
		let Route::Checkpoint(command) = request.route() else {
			panic!("checkpoint route")
		};
		assert_eq!(serde_json::to_value(command).unwrap(), row["command"]);
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
		"setRoomTopic",
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
	handed(&fixture, &CapturedRoutes(&fixture));
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[test]
fn handed_invitations_use_native_routes() {
	handed(&fixture(), &rooms_glowcap::routes::CheckpointRoutes);
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
