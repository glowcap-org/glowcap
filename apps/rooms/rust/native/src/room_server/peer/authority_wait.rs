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
