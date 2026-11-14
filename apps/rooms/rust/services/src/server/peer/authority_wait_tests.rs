//! A queued authority change decides against what the changes before it committed.
use super::writer_running::{change, writer_running};
use super::*;
use glowcap::Argument;
use rooms_application::room::stewardship::Kind;

#[tokio::test]
async fn waiting_revocation_cannot_retire_a_replacement_authority() {
	rooms_testing::local_set::run_within(
		std::time::Duration::from_secs(10),
		writer_running("revocation-wait", scenario),
	)
	.await;
}

async fn issue(shared: &Rc<RefCell<State>>) -> String {
	let issued = authority::queue::request(
		&shared.borrow(),
		"roomAuthorities",
		|state| Ok(state.authority.remembered("garden", false, false, None)?),
		|state| state.publish_room("garden").map(Argument::from),
	);
	issued.await.unwrap().as_str().unwrap().into()
}

/// Queue the prepare half of a link ask, the half that decides who is told.
fn ask_link(
	shared: &Rc<RefCell<State>>,
	asker: authority::Asker,
) -> impl Future<Output = Result<Argument, String>> + use<> {
	let prepare = authority::link_ask::prepare_link(asker);
	authority::queue::request(
		&shared.borrow(),
		"link",
		move |state| prepare(state).map(|(next, _)| next),
		|_| Ok(Argument::Void),
	)
}

async fn scenario(shared: Rc<RefCell<State>>) {
	let original = issue(&shared).await;
	// Capture the batch's intent but do not poll its admission.
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
}

#[tokio::test]
async fn queued_manager_revocation_cannot_borrow_a_replacement_manager_generation() {
	rooms_testing::local_set::run_within(
		std::time::Duration::from_secs(10),
		writer_running("manager-wait", |shared| async move {
			let room_token = issue(&shared).await;
			let issue_manager = || {
				authority::queue::request(
					&shared.borrow(),
					"giveManager",
					|state| Ok(state.authority.remembered("garden", false, true, None)?),
					|state| state.publish_manager("garden").map(Argument::from),
				)
			};
			let manager_token = issue_manager().await.unwrap().as_str().unwrap().to_owned();
			let generation = shared.borrow().authority.manager_generation("garden");
			let (prepare, commit) =
				authority::revocation(Kind::Room, room_token.clone(), Some(("garden".into(), generation)));
			let delayed = authority::queue::request(&shared.borrow(), "revoke", prepare, commit);
			let delayed_link = ask_link(
				&shared,
				authority::Asker::Manager {
					name: "garden".into(),
					generation,
				},
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
		}),
	)
	.await;
}

#[tokio::test]
async fn a_name_asking_for_a_link_behind_a_policy_change_meets_the_policy_it_commits() {
	rooms_testing::local_set::run_within(
		std::time::Duration::from_secs(10),
		writer_running("link-policy", |shared| async move {
			const ID: &str = "~1234567890abcdef1234567890abcdef";
			change(&shared, "roomAuthorities", |state| {
				Ok(state.authority.remembered(
					ID,
					false,
					true,
					Some(rooms_application::server::links::Registration {
						name: "salon",
						policy: rooms_application::room::policy::RoomPolicy::Open,
					}),
				)?)
			})
			.await
			.unwrap();
			// The ask is queued behind the change that moderates the room, and
			// the writer decides it against the policy that change committed.
			let moderate = change(&shared, "setRoomPolicy", |state| {
				Ok(state.authority.with_managed_room_policy(
					ID,
					"salon",
					rooms_application::room::policy::RoomPolicy::Moderated,
				)?)
			});
			let ask = ask_link(&shared, authority::Asker::Name("salon".into()));
			let (moderated, asked) = tokio::join!(moderate, ask);
			moderated.unwrap();
			let refused = asked.unwrap_err();
			assert!(refused.contains("read-only-membership"), "{refused}");
		}),
	)
	.await;
}

/// The ask's job runs after the forget commits, with no turn check before it,
/// so the job itself must resolve the name.
async fn ask_after_forget(label: &str, durable: &'static str, registered: Option<&'static str>, listed: &'static str) {
	rooms_testing::local_set::run_within(
		std::time::Duration::from_secs(10),
		writer_running(label, move |shared| async move {
			change(&shared, "roomAuthorities", move |state| {
				let registration = registered.map(|name| rooms_application::server::links::Registration {
					name,
					policy: rooms_application::room::policy::RoomPolicy::Open,
				});
				Ok(state
					.authority
					.remembered(durable, false, registration.is_some(), registration)?)
			})
			.await
			.unwrap();
			let forget = change(&shared, "forgetRoom", move |state| {
				Ok(state.authority.with_room_forgotten(durable)?)
			});
			let ask = ask_link(&shared, authority::Asker::Name(listed.into()));
			let (forgotten, asked) = tokio::join!(forget, ask);
			forgotten.unwrap();
			let refused = asked.unwrap_err();
			assert!(
				refused.contains("no-such-room") && refused.contains(&format!("no room named \"{listed}\"")),
				"{refused}"
			);
			let state = shared.borrow();
			assert!(
				!state.authority.room_link_active(durable),
				"the forgotten room has no link"
			);
			assert!(!state.authority.room_link_active(listed), "the listed name has no link");
		}),
	)
	.await;
}

#[tokio::test]
async fn a_name_asking_behind_the_forget_of_a_plain_room_is_told_no_such_room() {
	ask_after_forget("forget-plain", "garden", None, "garden").await;
}

#[tokio::test]
async fn a_name_asking_behind_the_forget_of_a_managed_room_is_told_no_such_room() {
	ask_after_forget(
		"forget-managed",
		"~1234567890abcdef1234567890abcdef",
		Some("salon"),
		"salon",
	)
	.await;
}
