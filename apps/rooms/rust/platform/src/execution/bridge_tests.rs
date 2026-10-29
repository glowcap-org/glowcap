//! Membership bridge calls use shared form admission and keep each room's
//! declaration separate, including while an earlier observation is cancelled. status-allow: event or source ordering
use super::HostPlatform;
use glowcap::{Argument, ConnectOptions, Host, ListenerIdentity, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::bridge::{self, Answers};
use rooms_glowcap::client::{Client, Error, room::Room};
use serde_json::{Value, json};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
	time::Duration,
};

#[tokio::test]
async fn bridge_forms_follow_membership_authority_and_cancelled_submissions_are_not_replayed() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), scenario())
				.await
				.expect("bridge scenario deadline");
		})
		.await;
}
async fn scenario() {
	let fixture: Value = serde_json::from_str(include_str!("../../../proofs/fixtures/bridge-client.json")).unwrap();
	let form = fixture["forms"][0]["raw"].as_str().unwrap().to_owned();
	let host = Host::from_seed([86; 32]).unwrap();
	let server = tcp::listen(
		"127.0.0.1",
		0,
		tcp::ListenOptions {
			identity: ListenerIdentity::Host(host.clone()),
			..Default::default()
		},
	)
	.await
	.unwrap();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let locator = server.locator().unwrap();
	let (connected, accepted) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let accepted = Rc::new(accepted.unwrap());
	let service = accepted.clone();
	let serving = tokio::task::spawn_local(async move { service.serve().await });
	let client = Client::new(connected.unwrap(), HostPlatform);
	let reply = Rc::new(RefCell::new(Ok(Argument::String(form.clone()))));
	let calls = Rc::new(RefCell::new(Vec::<Value>::new()));
	let delayed = Rc::new(Cell::new(false));
	let (tx, mut resolutions) = tokio::sync::mpsc::channel(1);
	let (answer, recorded, delay, actor_host) = (reply.clone(), calls.clone(), delayed.clone(), host.clone());
	let seat = accepted
		.spawn_owned(move |verb, args| match verb.ok_or("fixture requires a method")? {
			"bridgeForm" => {
				assert!(args.is_empty());
				answer.borrow().clone()
			}
			"submitBridgeForm" => {
				assert_eq!(args.len(), 2);
				recorded
					.borrow_mut()
					.push(json!({"verb":verb,"args":args.iter().map(|v|v.as_str().unwrap()).collect::<Vec<_>>()}));
				if delay.get() {
					tx.try_send(actor_host.defer_turn().unwrap()).unwrap();
					Ok(Argument::Void)
				} else {
					answer.borrow().clone()
				}
			}
			"leave" => Ok(Argument::Void),
			_ => Err("unknown membership verb".into()),
		})
		.unwrap();
	let other_seat = accepted
		.spawn_owned(|verb, args| {
			let verb = verb.ok_or("fixture requires a method")?;
			assert!(args.is_empty());
			match verb {
				"bridgeForm" | "leave" => Ok(Argument::Void),
				_ => Err("no bridge here".into()),
			}
		})
		.unwrap();
	let mut publications = Vec::new();
	for (name, member) in [("room", seat.clone()), ("other", other_seat.clone())] {
		let service = accepted.clone();
		publications.push(
			accepted
				.publish(name, move |verb, args| {
					let verb = verb.ok_or("fixture requires a method")?;
					assert_eq!(verb, "subscribe");
					let Argument::Reference(inbox) = &args[1] else {
						panic!("no inbox")
					};
					service
						.tell(
							inbox,
							"notify",
							&["room".into(), "".into(), "listed".into(), true.into()],
						)
						.unwrap();
					Ok(Argument::List(vec![
						member.clone().into(),
						"participant".into(),
						Argument::Void,
						Argument::Void,
					]))
				})
				.unwrap(),
		);
	}
	let (room, _messages) = Room::subscribe(
		client.clone(),
		client.session().fetch("room").await.unwrap(),
		"alice",
		Default::default(),
	)
	.await
	.unwrap();
	let (other, _messages) = Room::subscribe(
		client.clone(),
		client.session().fetch("other").await.unwrap(),
		"alice",
		Default::default(),
	)
	.await
	.unwrap();
	assert_eq!(
		room.bridge_form().await.unwrap().unwrap().scope.text().as_str(),
		Some("network")
	);
	assert!(other.bridge_form().await.unwrap().is_none());
	for row in fixture["wire"].as_array().unwrap() {
		*reply.borrow_mut() = Ok(match &row["input"] {
			Value::Null => Argument::Void,
			Value::Bool(on) => Argument::Boolean(*on),
			Value::String(text) => Argument::String(text.clone()),
			Value::Array(_) => Argument::List(vec![]),
			_ => Argument::Reference(other_seat.clone()),
		});
		let result = room.bridge_form().await;
		assert_eq!(result.is_err(), row["error"] == true);
		if let Ok(result) = result {
			assert_eq!(serde_json::to_value(result).unwrap(), row["result"]);
		}
	}
	*reply.borrow_mut() = Err("bridge unavailable".into());
	assert!(
		room.bridge_form()
			.await
			.unwrap_err()
			.to_string()
			.contains("bridge unavailable")
	);
	*reply.borrow_mut() = Ok(Argument::String(form.clone()));
	assert!(room.bridge_form().await.unwrap().is_some());
	for (index, call) in fixture["calls"].as_array().unwrap().iter().enumerate() {
		*reply.borrow_mut() = Ok(if index == 0 {
			"Identity linked".into()
		} else {
			other_seat.clone().into()
		});
		let answers = Answers::decode(call["args"][1].as_str().unwrap()).unwrap();
		let said = room
			.submit_bridge_form(call["args"][0].as_str().unwrap(), &answers)
			.await
			.unwrap();
		assert_eq!(
			said,
			if index == 0 {
				fixture["said"].as_str().unwrap()
			} else {
				fixture["defaultSaid"].as_str().unwrap()
			}
		);
	}
	assert_eq!(json!(*calls.borrow()), fixture["calls"]);
	let mut large = Answers::default();
	for i in 0..16 {
		large.insert(format!("a{i}"), "\0".repeat(512).into()).unwrap();
	}
	assert!(matches!(
		room.submit_bridge_form("link", &large).await,
		Err(Error::Bridge(bridge::Error::Size))
	));
	assert_eq!(calls.borrow().len(), 2, "oversized JSON must not reach the bridge");
	delayed.set(true);
	let empty = Answers::default();
	let mut pending = Box::pin(room.submit_bridge_form("disconnect", &empty));
	let mut resolver =
		tokio::select! { r = resolutions.recv() => r.unwrap(), _ = &mut pending => panic!("early submit answer") };
	drop(pending);
	assert!(other.bridge_form().await.unwrap().is_none());
	resolver.fulfill(&"late acknowledgement".into()).unwrap();
	assert_eq!(
		calls.borrow().len(),
		3,
		"cancelled submissions must not replay themselves"
	);
	room.leave().await.unwrap();
	assert!(matches!(room.bridge_form().await, Err(Error::Membership(_))));
	assert!(matches!(
		room.submit_bridge_form("link", &empty).await,
		Err(Error::Membership(_))
	));
	assert!(other.bridge_form().await.unwrap().is_none());
	other.leave().await.unwrap();
	drop((room, other, client));
	for reference in publications {
		accepted.release(reference).unwrap();
	}
	drop((seat, other_seat));
	accepted.close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.close().await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
}
