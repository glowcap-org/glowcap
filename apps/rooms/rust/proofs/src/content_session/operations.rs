//! Exact operations selections preserve interface, wire kinds and local custody.
use super::*;
use rooms_application::{
	content::session::{dispatch::Dispatch, local},
	session::{
		command::Request,
		effect::Argument as Data,
		operations::mutation::{self, Kind},
	},
};

fn dispatch(args: &[&str]) -> Result<Dispatch, rooms_application::content::session::dispatch::Refusal> {
	use crate::arguments::Arg;
	let mut wire = vec![
		Arg::Text("operation".into()),
		Arg::Integer(1),
		Arg::Text("operations".into()),
	];
	wire.extend(args.iter().map(|value| Arg::Text((*value).into())));
	Dispatch::parse(&Request::parse(&wire).unwrap())
}
pub fn run() {
	let handle = custody::Coordinate {
		role: custody::Role::Operations,
		key: key(1, 1),
	};
	let selection = workspace::Operations {
		connection: None,
		kind: Kind::Listeners,
		handle,
	};
	let mut intent = workspace::Intent::empty();
	intent.operations = rooms_application::fields::List::new(vec![selection.clone()]).unwrap();
	let coordinate = serde_json::to_string(&handle).unwrap();
	let down = dispatch(&[&coordinate, "listeners", "down", "7"]).unwrap();
	assert_eq!(down.target(&intent).unwrap(), handle);
	assert_eq!(down.mutation.args, [Data::Integer(7)]);
	assert!(down.target(&workspace::Intent::empty()).is_err());
	for id in ["0", "-1", "9007199254740992", "invalid"] {
		assert!(dispatch(&[&coordinate, "listeners", "down", id]).is_err());
	}
	assert!(
		dispatch(&[&coordinate, "clearTrouble"]).is_err(),
		"operator grammar cannot select an operations interface"
	);
	assert!(
		dispatch(&[&coordinate, "ircConnection", "closeConnection"])
			.unwrap()
			.target(&intent)
			.is_err()
	);
	let up = dispatch(&[&coordinate, "listeners", "up", "tcp", r#"{"port":9000}"#]).unwrap();
	assert_eq!(
		up.mutation.args,
		[
			Data::from("tcp"),
			Data::List(vec![Data::List(vec![Data::from("port"), Data::Integer(9000)])])
		]
	);
	for options in [
		"[]",
		"true",
		r#"{"port":1.5}"#,
		r#"{"host":true}"#,
		r#"{"":1}"#,
		r#"{"nested":{}}"#,
	] {
		assert!(dispatch(&[&coordinate, "listeners", "up", "tcp", options]).is_err());
	}
	for kind in [Kind::Diagnostics, Kind::Trace, Kind::Peering] {
		assert!(mutation::mutation(kind, "reset", &[]).is_err());
	}
	assert!(mutation::mutation(Kind::IrcGateway, "closeConnection", &[]).is_err());
	let acquired = mutation::mutation(Kind::IrcGateway, "connection", &["network".into()]).unwrap();
	assert_eq!(acquired.args, [Data::from("network")]);
	assert_eq!(acquired.reply, rooms_application::session::effect::Reply::IrcConnection);
	assert!(mutation::mutation(Kind::IrcGateway, "connection", &[String::new()]).is_err());
	assert!(mutation::mutation(Kind::IrcConnection, "connection", &["network".into()]).is_err());
	assert!(mutation::mutation(Kind::IrcConnection, "openConnection", &["{}".into()]).is_err());
	let mut fields = custody::Custody::<References>::default();
	fields
		.insert_operations(custody::Held {
			key: key(1, 1),
			reference: (),
		})
		.unwrap();
	fields
		.insert_operations(custody::Held {
			key: key(2, 1),
			reference: (),
		})
		.unwrap();
	assert!(intent.validate(&fields).is_ok());
	let mut invalid = intent.clone();
	invalid.operations.as_mut_slice()[0].handle.role = custody::Role::IrcConnection;
	assert!(invalid.validate(&fields).is_err());
	let next = workspace::Operations {
		connection: None,
		kind: Kind::Listeners,
		handle: custody::Coordinate {
			key: key(2, 1),
			..handle
		},
	};
	let raw = serde_json::to_string(&vec![next]).unwrap();
	use crate::arguments::Arg;
	let wire = [
		Arg::Text("replace".into()),
		Arg::Integer(1),
		Arg::Text("replaceOperationsBundle".into()),
		Arg::Text(raw),
	];
	local::apply(&Request::parse(&wire).unwrap(), &mut intent, &mut fields).unwrap();
	assert!(
		fields.get(handle).is_none(),
		"replacement retires unselected exact custody"
	);
	assert_eq!(intent.operations.as_slice().len(), 1);
}
