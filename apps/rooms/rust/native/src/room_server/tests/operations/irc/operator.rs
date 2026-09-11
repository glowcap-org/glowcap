//! The IRC rows and their acts, including persistence failure and replacements.
use super::cap;
use glowcap::{Argument, Ref, Session};
use std::path::Path;

pub(super) async fn rows(session: &Session, operator: &Ref, category: &str, query: &str) -> Vec<Vec<Argument>> {
	let result = session
		.send(
			operator,
			"operatorSnapshot",
			&[
				category.into(),
				Argument::Integer(0),
				Argument::Integer(32),
				query.into(),
			],
		)
		.await
		.unwrap();
	let Argument::List(page) = result else {
		panic!("operator page");
	};
	super::super::rows(&page[2])
}
pub(super) async fn member_reference(session: &Session, operator: &Ref) -> String {
	let references = rows(session, operator, "references", "net/#b alice").await;
	assert_eq!(references.len(), 1);
	assert_eq!(references[0][1], Argument::from("membership"));
	references[0][0].as_str().unwrap().into()
}
async fn retire(session: &Session, operator: &Ref, category: &str, query: &str) -> Vec<Argument> {
	let answer = session
		.send(
			operator,
			"operatorRetireMatching",
			&[category.into(), query.into(), Argument::Integer(16)],
		)
		.await
		.unwrap();
	let Argument::List(cells) = answer else {
		panic!("batch result");
	};
	cells
}

pub(super) async fn scenario(session: &Session, operator: &Ref, network: &Ref, state: &Path, moderator: &Ref) {
	let before = rows(session, operator, "rooms", "net/#b").await;
	assert_eq!(before.len(), 1);
	assert_eq!(before[0][1], Argument::from("irc"));
	assert_eq!(before[0][4], Argument::from("bridge"));
	assert_eq!(before[0][5], Argument::Integer(0));
	let id = before[0][0].clone();
	// Disk failure must leave both the visible row and its durable intent.
	let document = state.join(rooms_application::server::operations::document::FILE);
	let saved = state.with_extension("parked");
	std::fs::rename(state, &saved).unwrap();
	let failed = session
		.send(operator, "removeOperatorRoom", std::slice::from_ref(&id))
		.await;
	std::fs::rename(&saved, state).unwrap();
	assert!(failed
		.unwrap_err()
		.to_string()
		.contains("keeping the operations document failed"));
	assert_eq!(rows(session, operator, "rooms", "net/#b").await[0][0], id);
	assert!(session.send(moderator, "governs", &[]).await.is_ok());
	session
		.send(operator, "removeOperatorRoom", std::slice::from_ref(&id))
		.await
		.unwrap();
	assert!(rows(session, operator, "rooms", "net/#b").await.is_empty());
	assert!(session.send(moderator, "governs", &[]).await.is_err());
	for name in ["b", "c", "d"] {
		let ask = serde_json::json!({"channel":name}).to_string();
		session.send(network, "addLease", &[ask.into()]).await.unwrap();
	}
	let replacement = rows(session, operator, "rooms", "net/#b").await[0][0].clone();
	assert_ne!(replacement, id);
	assert!(session.send(operator, "removeOperatorRoom", &[id]).await.is_err());
	let issued = session.send(operator, "giveSteward", &["net/#c".into()]).await.unwrap();
	let Argument::List(row) = issued else {
		panic!("stewardship");
	};
	let token = super::token(row[5].as_str().unwrap());
	let steward = session.fetch(&token).await.unwrap();
	let batch = retire(session, operator, "stewardships", "net/#c").await;
	assert_eq!(batch, [Argument::Integer(1), Argument::Integer(1), "".into()]);
	assert!(session.send(&steward, "governs", &[]).await.is_err());
	let c = rows(session, operator, "stewardships", "net/#c").await;
	assert_eq!(c[0][4], Argument::Boolean(false));
	let document_now = std::fs::read_to_string(&document).unwrap();
	let kept = rooms_application::server::operations::document::Document::decode(&document_now).unwrap();
	assert!(!kept.irc_bridge_authority(row[0].as_str().unwrap()).unwrap().issued);

	// Release the exact inbox generation, including a sibling that shares its IRC identity.
	let directory = session.fetch("directory").await.unwrap();
	let mut seats = Vec::new();
	for channel in ["c", "d"] {
		let room = cap(session
			.send(&directory, "enter", &[format!("net/#{channel}").into()])
			.await
			.unwrap());
		let inbox = session.spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
		seats.push(super::member(
			session
				.send(&room, "subscribe", &["reader".into(), Argument::Reference(inbox)])
				.await
				.unwrap(),
		));
	}
	let references = rows(session, operator, "references", "net/#c reader").await;
	assert_eq!(references.len(), 1);
	session
		.send(operator, "releaseOperatorReference", &[references[0][0].clone()])
		.await
		.unwrap();
	assert!(session.send(&seats[0], "membershipKind", &[]).await.is_err());
	assert_eq!(
		session.send(&seats[1], "membershipKind", &[]).await.unwrap(),
		Argument::from("participant")
	);
	let batch = retire(session, operator, "rooms", "irc").await;
	assert_eq!(batch, [Argument::Integer(3), Argument::Integer(0), "".into()]);
	assert!(session.send(&seats[1], "membershipKind", &[]).await.is_err());
	session
		.send(network, "addLease", &[r#"{"channel":"reset"}"#.into()])
		.await
		.unwrap();
	session
		.send(operator, "resetOperatorScope", &["rooms".into()])
		.await
		.unwrap();
	assert!(rows(session, operator, "rooms", "irc").await.is_empty());
	let kept =
		rooms_application::server::operations::document::Document::decode(&std::fs::read_to_string(&document).unwrap())
			.unwrap();
	assert!(kept.irc_bridges.is_empty());
	assert!(kept.irc_bridge_authorities.is_empty());
	assert_eq!(
		kept.irc_networks.len(),
		1,
		"reset rooms retains the network configuration"
	);
}
