use super::{
	arguments::{Arg, from_fixture},
	grants::{MemoryStore, ready},
};
use rooms_application::grants::{
	Access, Command, GrantLedger,
	protocol::{self, GrantView},
};
use std::{cell::Cell, rc::Rc};

pub fn run() {
	let cases: serde_json::Value = serde_json::from_str(include_str!("../fixtures/grant-commands.json")).unwrap();
	for row in cases.as_array().unwrap() {
		let access = match row["access"].as_str().unwrap() {
			"admin" => Access::Admin,
			"interact" => Access::Interact,
			"observe" => Access::Observe,
			_ => Access::None,
		};
		let args: Vec<_> = row["args"].as_array().unwrap().iter().map(from_fixture).collect();
		let command = protocol::read(access, row["verb"].as_str().unwrap(), &args);
		assert_eq!(command.is_some(), row["handled"].as_bool().unwrap());
		let Some(command) = command else {
			continue;
		};
		let mut ledger = GrantLedger::restore(include_bytes!("../fixtures/grants-v1.json")).unwrap();
		let mut disk = Vec::new();
		let result = command.map_err(|e| e.to_string()).and_then(|command| {
			let id = match &command {
				Command::Issue { id, .. } | Command::SetPolicy { id, .. } | Command::Revoke { id } => id.clone(),
			};
			let revoke = matches!(command, Command::Revoke { .. });
			ready(ledger.apply(&mut MemoryStore(&mut disk), command)).map_err(|e| format!("{e:?}"))?;
			if revoke {
				return Ok(serde_json::Value::Null);
			}
			let view = GrantView::from_grant(ledger.get(&id).unwrap().unwrap(), format!("ocapn://fixture.tcp/s/{id}"))
				.unwrap();
			let encoded = view.encode().unwrap();
			let decoded = GrantView::decode(&encoded).unwrap();
			Ok(serde_json::to_value(decoded).unwrap())
		});
		assert_eq!(result.is_ok(), row["accepted"].as_bool().unwrap(), "{row}: {result:?}");
		if let Ok(reply) = result {
			assert_eq!(reply, row["reply"]);
		}
	}
	let drops = Rc::new(Cell::new(0));
	let args = [Arg::List(vec![Arg::Capability(drops.clone())])];
	assert!(matches!(
		protocol::read(Access::Admin, protocol::REVOKE, &args),
		Some(Err(protocol::Refusal::Capability))
	));
	assert_eq!(drops.get(), 0);
	drop(args);
	assert_eq!(drops.get(), 1);
	let ledger = GrantLedger::restore(include_bytes!("../fixtures/grants-surrogate-v1.json")).unwrap();
	let grant = ledger.get("00000000-0000-4000-8000-000000000003").unwrap().unwrap();
	let encoded = GrantView::from_grant(grant, "ocapn://fixture.tcp/s/fixture".into())
		.unwrap()
		.encode()
		.unwrap();
	assert_eq!(
		GrantView::decode(&encoded).unwrap().label.utf16().collect::<Vec<_>>(),
		vec![0xd800]
	);
	for malformed in ["null", "{}", "[]", "42"] {
		assert!(GrantView::decode(malformed).is_err());
	}
	assert!(GrantView::decode(&" ".repeat(102_000)).is_err());
}
