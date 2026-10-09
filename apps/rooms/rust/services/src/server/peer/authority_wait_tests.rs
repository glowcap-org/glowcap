//! A waiting operator act carries a token, not a name to resolve after waiting.
use super::*;
use glowcap::Argument;
use rooms_application::room::stewardship::Kind;

#[tokio::test]
async fn waiting_revocation_cannot_retire_a_replacement_authority() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(std::time::Duration::from_secs(10), scenario())
				.await
				.unwrap();
		})
		.await;
}

async fn issue(shared: &Rc<RefCell<State>>) -> String {
	let issued = authority::queue::request(
		&shared.borrow(),
		"roomAuthorities",
		|state| Ok(state.authority.remembered("garden", false, false, None, None)?),
		|state| state.publish_room("garden").map(Argument::from),
	);
	issued.await.unwrap().as_str().unwrap().into()
}

async fn scenario() {
	let config = Config::parse(["--transport=tcp".into()], |_| None).unwrap().unwrap();
	let mut peer = Peer::open(config, Rc::new(|_| {})).await.unwrap();
	let shared = peer.state.clone();
	let writer = peer.owners.authority.take().unwrap();
	let writing = tokio::task::spawn_local(writer.run(shared.clone()));
	let original = issue(&shared).await;
	// Capture the batch's intent but deliberately do not poll its admission.
	let delayed = authority::request_revoke(&shared.borrow(), Kind::Room, original.clone());
	let revoke_now = authority::request_revoke(&shared.borrow(), Kind::Room, original.clone());
	revoke_now.await.unwrap();
	let replacement = issue(&shared).await;
	assert_ne!(replacement, original);
	assert!(delayed.await.is_err());
	assert_eq!(
		shared.borrow().links.swiss(Kind::Room, "garden"),
		Some(replacement.as_str())
	);
	assert!(shared.borrow().authority.linked_rooms().any(|name| name == "garden"));
	shared.borrow().authority_writer.stop();
	writing.await.unwrap();
	drop(shared);
	peer.close().await.unwrap();
}

#[tokio::test]
async fn queued_manager_revocation_cannot_borrow_a_replacement_manager_generation() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(std::time::Duration::from_secs(10), async {
				let config = Config::parse(["--transport=tcp".into()], |_| None).unwrap().unwrap();
				let mut peer = Peer::open(config, Rc::new(|_| {})).await.unwrap();
				let shared = peer.state.clone();
				let writer = peer.owners.authority.take().unwrap();
				let writing = tokio::task::spawn_local(writer.run(shared.clone()));
				let room_token = issue(&shared).await;
				let issue_manager = || {
					authority::queue::request(
						&shared.borrow(),
						"giveManager",
						|state| Ok(state.authority.remembered("garden", false, true, None, None)?),
						|state| state.publish_manager("garden").map(Argument::from),
					)
				};
				let manager_token = issue_manager().await.unwrap().as_str().unwrap().to_owned();
				let generation = shared.borrow().authority.manager_generation("garden");
				let (prepare, commit) =
					authority::revocation(Kind::Room, room_token.clone(), Some(("garden".into(), generation)));
				let delayed = authority::queue::request(&shared.borrow(), "revoke", prepare, commit);
				let delayed_link = authority::queue::request(
					&shared.borrow(),
					"link",
					authority::prepare_link("garden".into(), Some(generation)),
					|state| state.publish_room("garden").map(Argument::from),
				);
				let revoke = authority::request_revoke(&shared.borrow(), Kind::Manager, manager_token.clone());
				revoke.await.unwrap();
				let replacement = issue_manager().await.unwrap();
				assert_ne!(replacement.as_str(), Some(manager_token.as_str()));
				assert!(delayed.await.unwrap_err().contains("manager capability was revoked"));
				assert!(
					delayed_link
						.await
						.unwrap_err()
						.contains("manager capability was revoked")
				);
				assert_eq!(
					shared.borrow().links.swiss(Kind::Room, "garden"),
					Some(room_token.as_str())
				);
				shared.borrow().authority_writer.stop();
				writing.await.unwrap();
				drop(shared);
				peer.close().await.unwrap();
			})
			.await
			.expect("manager generation deadline");
		})
		.await;
}
