#[path = "handed_custody.rs"]
mod custody;
use super::*;
use crate::session_runtime::handed_rooms::{HandedReceiver, HandedRooms};
use glowcap::{Ref, Resolver};
use rooms_application::{
	room::{authority, handoff},
	session::checkpoint::reconciliation::Id,
};
use rooms_glowcap::client::direct::receiver;
use std::cell::Cell;

struct Harness {
	fixture: Fixture,
	rooms: HandedRooms,
	worker: tokio::task::JoinHandle<Result<(), rooms_runtime::Error>>,
	dispatch: DirectDispatcher,
	dispatch_worker: tokio::task::JoinHandle<Result<(), rooms_runtime::Error>>,
	_contexts: [AcceptedDirect; 2],
	offers: [peers::Offer; 2],
	_outcomes: Outcomes,
}
impl Harness {
	async fn new(name: &str) -> Self {
		let mut fixture = Fixture::new(name).await;
		let (rooms, worker) = fixture.runtime.handed_rooms();
		let receiver = rooms.receiver();
		let mut ordinary =
			crate::session_runtime::tests::route_openings::factory(fixture.lines.receiver(), fixture.routes.receiver());
		let (dispatch, direct_worker, mut outcomes) = DirectDispatcher::new(
			fixture.runtime.clone(),
			fixture.inbox.take().unwrap(),
			fixture.publisher.clone(),
			fixture.routes.receiver(),
			Rc::new(|_| {}),
			move |context| {
				let mut regular = ordinary(context.clone())?;
				let received = receiver.clone();
				let mut hands = receiver_for(received, context);
				Ok(Box::new(move |verb, args| {
					if verb == rooms_application::direct::HAND_ROOM {
						hands(verb, args)
					} else {
						regular(verb, args)
					}
				}))
			},
		);
		let worker = tokio::task::spawn_local(worker.run());
		let dispatch_worker = tokio::task::spawn_local(direct_worker.run());
		fixture.arrival.notify("mintInboxFor").await;
		let first = published(&mut outcomes).await;
		let offer = fixture.peer.offers.recv().await.unwrap();
		fixture.other_arrival.notify("mintInboxFor").await;
		let second = published(&mut outcomes).await;
		let other = fixture.other.offers.recv().await.unwrap();
		Self {
			fixture,
			rooms,
			worker,
			dispatch,
			dispatch_worker,
			_contexts: [first, second],
			offers: [offer, other],
			_outcomes: outcomes,
		}
	}
	fn revision(&self) -> u64 {
		self.fixture.commands.view().read(|s| s.revision()).unwrap().unwrap()
	}
	fn checkpoint(&self) -> Value {
		self.fixture
			.commands
			.view()
			.read(|s| serde_json::from_str(&s.checkpoint().unwrap().encode_for(Access::Admin).unwrap()).unwrap())
			.unwrap()
	}
	async fn hand(&self, index: usize, source: &Source, label: &str) -> Id {
		let offer = &self.offers[index];
		offer
			.session
			.send(
				&offer.inbox,
				"handRoom",
				&[label.into(), source.reference.clone().into()],
			)
			.await
			.unwrap();
		self.rooms.read(|rows| {
			rows.iter()
				.find(|row| row.label.text().as_str() == Some(label))
				.unwrap()
				.id
				.clone()
		})
	}
	async fn close(self) {
		self.rooms.close().await.unwrap();
		self.worker.await.unwrap().unwrap();
		self.dispatch.close().await.unwrap();
		self.dispatch_worker.await.unwrap().unwrap();
		drop((self.rooms, self.offers, self._contexts, self._outcomes));
		self.fixture.close().await;
	}
}
fn receiver_for(
	received: HandedReceiver,
	context: AcceptedDirect,
) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	receiver(move |notice, session| {
		let rooms_application::direct::Notice::HandRoom { label, room } = notice else {
			return Err("expected handed room".into());
		};
		received
			.receive(&context, session, label, room)
			.map_err(rooms_runtime::Error::into_refusal)?;
		Ok(Argument::Void)
	})
}
struct Source {
	reference: Ref,
	calls: Rc<Cell<usize>>,
	answers: mpsc::Receiver<Resolver>,
}
impl Source {
	fn new(offer: &peers::Offer) -> Self {
		let calls = Rc::new(Cell::new(0));
		let called = calls.clone();
		let (answer, answers) = mpsc::channel(16);
		let reference = offer
			.session
			.publish("handed-source", move |verb, _| {
				if verb != authority::LINK {
					return Err("only link is expected".into());
				}
				let permit = answer.try_reserve().map_err(|_| "test room link queue is full")?;
				let session = glowcap::current_session()
					.map_err(|e| e.to_string())?
					.ok_or("test room needs its caller")?;
				let resolver = session.host().defer_turn().map_err(|e| e.to_string())?;
				called.set(called.get() + 1);
				permit.send(resolver);
				Ok(Argument::Void)
			})
			.unwrap();
		Self {
			reference,
			calls,
			answers,
		}
	}
}

#[tokio::test]
async fn room_handoff_receipt_acceptance_coalescing_and_durable_replay() {
	deadline(async {
		let harness = Harness::new("handed-accept").await;
		let mut source = Source::new(&harness.offers[0]);
		let before = harness.checkpoint();
		let id = harness.hand(0, &source, "private").await;
		assert_eq!(source.calls.get(), 0, "arrival must not mint a durable bearer");
		assert_eq!(harness.checkpoint(), before);
		harness.rooms.read(|rows| {
			assert_eq!(rows.len(), 1);
			assert_eq!(rows[0].directory, *harness._contexts[0].directory());
			assert_eq!(rows[0].from.text().as_str(), Some("bob"));
		});
		let base = harness.revision();
		assert!(
			harness
				.rooms
				.accept(text("bad-base"), base + 1, id.clone(), text("private"))
				.unwrap()
				.wait()
				.await
				.is_err()
		);
		assert_eq!(source.calls.get(), 0, "preflight must precede linking");
		let first = harness
			.rooms
			.accept(text("accept"), base, id.clone(), text("private"))
			.unwrap();
		let repeated = harness
			.rooms
			.accept(text("accept"), base, id.clone(), text("private"))
			.unwrap();
		assert!(
			harness
				.rooms
				.accept(text("accept"), base, id.clone(), text("different"))
				.is_err()
		);
		let mut answer = source.answers.recv().await.unwrap();
		assert_eq!(source.calls.get(), 1);
		drop(first);
		answer.fulfill(&"ocapn://offered.id/s/cHJpdmF0ZQ".into()).unwrap();
		assert_eq!(repeated.wait().await.unwrap(), base + 1);
		assert_eq!(harness.rooms.read(|rows| rows.len()), 0);
		assert_eq!(harness.checkpoint()["invitations"].as_array().unwrap().len(), 0);
		let checkpoint = harness.checkpoint();
		let room = checkpoint["conversations"]
			.as_array()
			.unwrap()
			.iter()
			.find(|row| row["id"] == "private")
			.unwrap();
		assert_eq!(room["directory"], "ocapn://offered.id");
		assert_eq!(room["link"], "ocapn://offered.id/s/cHJpdmF0ZQ");
		assert_eq!(
			harness
				.rooms
				.accept(text("accept"), base, id.clone(), text("private"))
				.unwrap()
				.wait()
				.await
				.unwrap(),
			base + 1
		);
		assert!(
			harness
				.rooms
				.accept(text("accept"), base, id.clone(), text("wrong"))
				.unwrap()
				.wait()
				.await
				.is_err()
		);
		assert_eq!(
			source.calls.get(),
			1,
			"durable replay must not need the retired handoff"
		);
		drop(source);
		harness.close().await;
	})
	.await;
}

#[tokio::test]
async fn room_handoffs_survive_their_direct_and_expire_independently_with_directory_or_connection() {
	deadline(async {
		let harness = Harness::new("handed-lifetimes").await;
		let source = Source::new(&harness.offers[0]);
		let mut other = Source::new(&harness.offers[1]);
		let first = harness.hand(0, &source, "first").await;
		let second = harness.hand(1, &other, "second").await;
		command(
			&harness.fixture.commands,
			"close-direct",
			Command::CloseDirect,
			vec![harness._contexts[0].conversation().text().clone()],
		)
		.await;
		assert_eq!(
			harness.rooms.read(|rows| rows.len()),
			2,
			"closing the carrying direct does not revoke a handoff"
		);
		let mut changes = harness.rooms.changes();
		command(
			&harness.fixture.commands,
			"remove-directory",
			Command::LeaveDirectory,
			vec![harness._contexts[0].directory().text().clone()],
		)
		.await;
		changes.changed().await.unwrap();
		assert_eq!(harness.rooms.read(|rows| rows.len()), 1);
		assert!(!harness.rooms.decline(&first));
		let pending = harness
			.rooms
			.accept(text("expires"), harness.revision(), second.clone(), text("second-room"))
			.unwrap();
		let mut answer = other.answers.recv().await.unwrap();
		harness.offers[1].session.close(PendingWork::Cancel).await.unwrap();
		assert!(pending.wait().await.is_err());
		assert_eq!(harness.rooms.read(|rows| rows.len()), 0);
		let _ = answer.fulfill(&"ocapn://offered.id/s/bGF0ZQ".into());
		assert!(
			harness.checkpoint()["conversations"]
				.as_array()
				.unwrap()
				.iter()
				.all(|row| row["id"] != "second-room")
		);
		drop((source, other));
		harness.close().await;
	})
	.await;
}

#[tokio::test]
async fn room_handoff_pressure_decline_revision_race_cache_and_owned_shutdown() {
	deadline(async {
		let harness = Harness::new("handed-pressure").await;
		let mut source = Source::new(&harness.offers[0]);
		let mut ids = Vec::new();
		for index in 0..handoff::LIMIT {
			ids.push(harness.hand(0, &source, &format!("room-{index}")).await);
		}
		let offer = &harness.offers[0];
		assert!(
			offer
				.session
				.send(
					&offer.inbox,
					"handRoom",
					&["overflow".into(), source.reference.clone().into()]
				)
				.await
				.is_err()
		);
		assert_eq!(source.calls.get(), 0);
		let base = harness.revision();
		let pending = harness
			.rooms
			.accept(text("racing"), base, ids[0].clone(), text("racing-room"))
			.unwrap();
		let mut answer = source.answers.recv().await.unwrap();
		command(
			&harness.fixture.commands,
			"advance",
			Command::SetStanding,
			vec!["busy".into()],
		)
		.await;
		answer.fulfill(&"ocapn://offered.id/s/cmFjZQ".into()).unwrap();
		assert!(
			pending.wait().await.is_err(),
			"preflight cannot reserve a checkpoint revision across the wire await"
		);
		assert_eq!(harness.rooms.read(|rows| rows.len()), handoff::LIMIT);
		let retry = harness
			.rooms
			.accept(text("racing"), harness.revision(), ids[0].clone(), text("racing-room"))
			.unwrap();
		assert_eq!(retry.wait().await.unwrap(), base + 2);
		assert_eq!(
			source.calls.get(),
			1,
			"a valid returned bearer is reused after a revision refusal"
		);
		let pending = harness
			.rooms
			.accept(
				text("declined"),
				harness.revision(),
				ids[1].clone(),
				text("declined-room"),
			)
			.unwrap();
		let mut answer = source.answers.recv().await.unwrap();
		assert!(harness.rooms.decline(&ids[1]));
		assert!(pending.wait().await.is_err());
		answer.fulfill(&"ocapn://offered.id/s/ZGVjbGluZWQ".into()).unwrap();
		let pending = harness
			.rooms
			.accept(
				text("shutdown"),
				harness.revision(),
				ids[2].clone(),
				text("shutdown-room"),
			)
			.unwrap();
		let answer = source.answers.recv().await.unwrap();
		drop(pending);
		harness.rooms.close().await.unwrap();
		assert_eq!(harness.rooms.read(|rows| rows.len()), 0);
		assert!(
			harness
				.rooms
				.accept(text("closed"), 0, ids[3].clone(), text("closed-room"))
				.is_err()
		);
		drop((answer, source));
		harness.close().await;
	})
	.await;
}
