use super::*;
use crate::session_runtime::room_offers::RoomOffers;
use rooms_glowcap::client::direct::receiver;

#[tokio::test]
async fn actual_room_offers_persist_before_acknowledgement_and_use_the_offered_directory() {
	deadline(async {
		let mut fixture = Fixture::new("room-links").await;
		let links = fixture.runtime.room_links();
		let (offers, offer_worker, mut pending) = RoomOffers::new(links.clone());
		let offer_task = tokio::task::spawn_local(offer_worker.run());
		let (dispatch, worker, mut outcomes) = dispatcher(&mut fixture, &offers);
		let task = tokio::task::spawn_local(worker.run());
		fixture.arrival.notify("mintInboxFor").await;
		let context = published(&mut outcomes).await;
		let offer = fixture.peer.offers.recv().await.unwrap();
		let target = "ocapn://offered.id/s/cm9vbQ";
		for _ in 0..2 {
			let (sent, revision) = tokio::join!(
				async {
					offer
						.session
						.send(&offer.inbox, "offerRoom", &["private".into(), target.into()])
						.await
				},
				async {
					let outcome = pending.next().await.unwrap();
					assert!(outcome.acknowledged.is_ok());
					let revision = outcome.revision.unwrap();
					let checkpoint: Value = fixture
						.commands
						.view()
						.read(|s| {
							serde_json::from_str(&s.checkpoint().unwrap().encode_for(Access::Admin).unwrap()).unwrap()
						})
						.unwrap();
					let invitations = checkpoint["invitations"].as_array().unwrap();
					assert_eq!(invitations.len(), 1);
					assert_eq!(invitations[0]["directory"], "ocapn://offered.id");
					assert_eq!(invitations[0]["locator"], "ocapn://offered.id");
					assert_eq!(invitations[0]["nick"], "alice");
					assert_eq!(invitations[0]["from"], "bob");
					assert_eq!(invitations[0]["link"], target);
					revision
				}
			);
			assert!(matches!(sent.unwrap(), Argument::Void));
			assert_eq!(
				fixture.commands.view().read(|s| s.revision()).unwrap().unwrap(),
				revision
			);
		}
		assert!(
			offer
				.session
				.send(&offer.inbox, "offerRoom", &["invalid".into(), "not a sturdyref".into()])
				.await
				.is_err()
		);
		assert!(
			Box::pin(pending.next())
				.as_mut()
				.poll(&mut Context::from_waker(Waker::noop()))
				.is_pending()
		);
		let (foreign, foreign_worker, foreign_events, foreign_inbox) = DirectoryRuntime::new(
			fixture.transport.clone(),
			fixture.commands.clone(),
			"ocapn://foreign.id".into(),
			rooms_platform::HostPlatform,
			rooms_platform::OsEntropy,
		)
		.unwrap();
		assert!(foreign.room_links().prepare(&context, "wrong owner", target).is_err());
		drop((foreign, foreign_worker, foreign_events, foreign_inbox));
		let close = fixture
			.commands
			.prepare_command(
				text("close-offer-direct"),
				fixture.commands.view().read(|s| s.revision()).unwrap().unwrap(),
				Command::CloseDirect,
				vec![context.conversation().text().clone()],
			)
			.unwrap()
			.send()
			.unwrap();
		let admitted = links
			.prepare(&context, "independent", "ocapn://offered.id/s/c2Vjb25k")
			.unwrap()
			.send()
			.unwrap();
		close.wait().await.unwrap();
		admitted.wait().await.unwrap();
		assert!(links.prepare(&context, "late", target).is_err());
		let count = fixture
			.commands
			.view()
			.read(|s| {
				let value: Value =
					serde_json::from_str(&s.checkpoint().unwrap().encode_for(Access::Admin).unwrap()).unwrap();
				value["invitations"].as_array().unwrap().len()
			})
			.unwrap();
		assert_eq!(count, 2, "received durable links survive the carrying conversation");
		fixture.other_arrival.notify("mintInboxFor").await;
		let other = published(&mut outcomes).await;
		drop(fixture.other.offers.recv().await.unwrap());
		offers.close().await.unwrap();
		offer_task.await.unwrap().unwrap();
		dispatch.close().await.unwrap();
		task.await.unwrap().unwrap();
		let mut closing = Box::pin(fixture.runtime.close());
		assert!(
			closing
				.as_mut()
				.poll(&mut Context::from_waker(Waker::noop()))
				.is_pending()
		);
		assert!(other.current(), "the directory worker has not yet polled retirement");
		assert!(links.prepare(&other, "stopping directory", target).is_err());
		drop(closing);
		drop(offer);
		fixture.close().await;
	})
	.await;
}

fn dispatcher(
	fixture: &mut Fixture,
	offers: &RoomOffers,
) -> (
	DirectDispatcher,
	crate::session_runtime::direct_dispatch::DirectWorker,
	Outcomes,
) {
	let received = offers.receiver();
	let mut ordinary =
		crate::session_runtime::tests::route_openings::factory(fixture.lines.receiver(), fixture.routes.receiver());
	DirectDispatcher::new(
		fixture.runtime.clone(),
		fixture.inbox.take().unwrap(),
		fixture.publisher.clone(),
		fixture.routes.receiver(),
		Rc::new(|_| {}),
		move |context| {
			let mut regular = ordinary(context.clone())?;
			let received = received.clone();
			let mut offers = receiver(move |notice, session| {
				let rooms_application::direct::Notice::OfferRoom { label, link } = notice else {
					return Err("expected a room offer".into());
				};
				received
					.receive(&context, &session, label, link)
					.map_err(rooms_runtime::Error::into_refusal)
			});
			Ok(Box::new(move |verb, args| {
				if verb == rooms_application::direct::OFFER_ROOM {
					offers(verb, args)
				} else {
					regular(verb, args)
				}
			}))
		},
	)
}

#[tokio::test]
async fn room_offer_outcomes_retain_capacity_and_report_durable_refusal_and_consumer_loss() {
	deadline(async {
		let mut fixture = Fixture::new("offer-outcomes").await;
		let (offers, worker, mut receipts) = RoomOffers::new(fixture.runtime.room_links());
		let offer_task = tokio::task::spawn_local(worker.run());
		let (dispatch, worker, mut outcomes) = dispatcher(&mut fixture, &offers);
		let task = tokio::task::spawn_local(worker.run());
		fixture.arrival.notify("mintInboxFor").await;
		let context = published(&mut outcomes).await;
		let offer = fixture.peer.offers.recv().await.unwrap();
		let target = "ocapn://offered.id/s/cm9vbQ";
		let mut held = Vec::new();
		for _ in 0..crate::session_runtime::room_offers::RECEIPT_LIMIT {
			offer
				.session
				.send(&offer.inbox, "offerRoom", &["private".into(), target.into()])
				.await
				.unwrap();
			let outcome = receipts.next().await.unwrap();
			assert!(outcome.revision.is_ok() && outcome.acknowledged.is_ok());
			assert_eq!(outcome.context.conversation(), context.conversation());
			held.push(outcome);
		}
		assert!(
			offer
				.session
				.send(&offer.inbox, "offerRoom", &["full".into(), target.into()])
				.await
				.is_err()
		);
		drop(held.pop());
		offer
			.session
			.send(&offer.inbox, "offerRoom", &["released".into(), target.into()])
			.await
			.unwrap();
		drop(receipts.next().await.unwrap());
		drop(held);
		for index in 1..16 {
			let link = glowcap::format_sturdyref(
				&glowcap::parse_locator("ocapn://offered.id").unwrap(),
				format!("room-{index}").as_bytes(),
				glowcap::CaptpVersion::V1_0,
			)
			.unwrap();
			offer
				.session
				.send(&offer.inbox, "offerRoom", &["another".into(), link.into()])
				.await
				.unwrap();
			let outcome = receipts.next().await.unwrap();
			assert!(outcome.revision.is_ok() && outcome.acknowledged.is_ok());
		}
		assert!(
			offer
				.session
				.send(
					&offer.inbox,
					"offerRoom",
					&["overflow".into(), "ocapn://offered.id/s/b3ZlcmZsb3c".into()]
				)
				.await
				.is_err()
		);
		let refused = receipts.next().await.unwrap();
		assert!(refused.revision.is_err());
		assert!(
			refused.acknowledged.is_ok(),
			"delivering a durable refusal is a successful wire reply"
		);
		drop(refused);
		drop(receipts);
		assert!(
			offer
				.session
				.send(&offer.inbox, "offerRoom", &["no consumer".into(), target.into()])
				.await
				.is_err()
		);
		assert!(offers.close().await.unwrap_err().to_string().contains("consumer"));
		assert!(offer_task.await.unwrap().is_err());
		assert!(offer.session.is_open());
		dispatch.close().await.unwrap();
		task.await.unwrap().unwrap();
		drop(offer);
		fixture.close().await;
	})
	.await;
}

#[tokio::test]
async fn room_offer_shutdown_drains_deferred_replies_after_commit_and_caller_abandonment() {
	deadline(async {
		let mut fixture = Fixture::new("offer-drain").await;
		let (offers, offer_worker, mut receipts) = RoomOffers::new(fixture.runtime.room_links());
		// Hold this worker without driving it. SessionCommands continues to own
		// persistence, so a committed receipt can have a still-deferred answer.
		let (dispatch, worker, mut outcomes) = dispatcher(&mut fixture, &offers);
		let task = tokio::task::spawn_local(worker.run());
		fixture.arrival.notify("mintInboxFor").await;
		let context = published(&mut outcomes).await;
		let offer = fixture.peer.offers.recv().await.unwrap();
		let revision = || fixture.commands.view().read(|s| s.revision()).unwrap().unwrap();
		let base = revision();
		let mut wire = Box::pin(async {
			offer
				.session
				.send(
					&offer.inbox,
					"offerRoom",
					&["private".into(), "ocapn://offered.id/s/cm9vbQ".into()],
				)
				.await
		});
		assert!(wire.as_mut().poll(&mut Context::from_waker(Waker::noop())).is_pending());
		while revision() == base {
			tokio::task::yield_now().await;
		}
		assert_eq!(revision(), base + 1);
		assert!(
			wire.as_mut().poll(&mut Context::from_waker(Waker::noop())).is_pending(),
			"persistence alone cannot discard the deferred reply"
		);
		let mut abandoned = Box::pin(async {
			offer
				.session
				.send(
					&offer.inbox,
					"offerRoom",
					&["another".into(), "ocapn://offered.id/s/YW5vdGhlcg".into()],
				)
				.await
		});
		assert!(
			abandoned
				.as_mut()
				.poll(&mut Context::from_waker(Waker::noop()))
				.is_pending()
		);
		while revision() == base + 1 {
			tokio::task::yield_now().await;
		}
		drop(abandoned);
		let mut closing = Box::pin(offers.close());
		assert!(
			closing
				.as_mut()
				.poll(&mut Context::from_waker(Waker::noop()))
				.is_pending()
		);
		drop(closing);
		assert!(
			context.current(),
			"closing only receipt ownership preserves the conversation"
		);
		let offer_task = tokio::task::spawn_local(offer_worker.run());
		assert!(matches!(wire.await.unwrap(), Argument::Void));
		offers.close().await.unwrap();
		offer_task.await.unwrap().unwrap();
		for expected in [base + 1, base + 2] {
			assert_eq!(receipts.next().await.unwrap().revision.unwrap(), expected);
		}
		assert!(receipts.next().await.is_none());
		assert_eq!(revision(), base + 2);
		dispatch.close().await.unwrap();
		task.await.unwrap().unwrap();
		drop(offer);
		fixture.close().await;
	})
	.await;
}
