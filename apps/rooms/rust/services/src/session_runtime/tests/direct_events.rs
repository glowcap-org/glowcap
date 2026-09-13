use super::*;
use crate::session_runtime::direct_events::{Content, EVENT_LIMIT};
use rooms_application::room::message::ChangeKind;

#[tokio::test]
async fn typing_and_line_changes_share_order_custody_and_conversation_lifetimes() {
	deadline(async {
		let mut fixture = Fixture::new("direct-events").await;
		let (dispatch, worker, mut outcomes) = fixture.dispatcher();
		let task = tokio::task::spawn_local(worker.run());
		fixture.arrival.notify("mintInboxFor").await;
		let first = published(&mut outcomes).await;
		let offer = fixture.peer.offers.recv().await.unwrap();
		fixture.other_arrival.notify("mintInboxFor").await;
		let second = published(&mut outcomes).await;
		let other = fixture.other.offers.recv().await.unwrap();
		let checkpoint = || {
			fixture
				.commands
				.view()
				.read(|s| s.checkpoint().unwrap().encode_for(Access::Admin).unwrap())
				.unwrap()
		};
		let before = checkpoint();
		offer.typing().await.unwrap();
		let Argument::Reference(line) = offer.session.send(&offer.inbox, "dm", &["one".into()]).await.unwrap() else {
			panic!("posted line");
		};
		other.typing().await.unwrap();
		offer.session.send(&line, "edit", &["edited".into()]).await.unwrap();
		offer
			.session
			.send(&offer.inbox, "typing", &[false.into()])
			.await
			.unwrap();
		let mut events = Vec::new();
		for _ in 0..5 {
			events.push(fixture.events.next().await.unwrap());
		}
		assert!(matches!(events[0].content, Content::Typing { on: true }));
		assert_eq!(events[1].line().unwrap().text, "one");
		assert!(matches!(events[2].content, Content::Typing { on: true }));
		assert_eq!(events[2].context.conversation(), second.conversation());
		assert_eq!(events[3].line().unwrap().kind, ChangeKind::Edited);
		assert_eq!(events[3].line().unwrap().text, "edited");
		assert!(matches!(events[4].content, Content::Typing { on: false }));
		assert!(
			events
				.iter()
				.all(|event| event.at > 0 && event.generation == events[0].generation)
		);
		assert_eq!(
			events.iter().filter_map(|event| event.line()).count(),
			2,
			"typing cannot supply an archive line"
		);
		assert_eq!(events[0].context.conversation(), first.conversation());
		let first_id = events[1].line().unwrap().line;
		assert_eq!(first_id, events[3].line().unwrap().line);
		drop(events);
		offer.session.send(&offer.inbox, "dm", &["two".into()]).await.unwrap();
		let next = fixture.events.next().await.unwrap();
		assert_eq!(
			next.line().unwrap().line.get(),
			first_id.get() + 1,
			"typing does not spend line identifiers"
		);
		drop(next);
		assert_eq!(checkpoint(), before, "transient typing has no checkpoint effect");
		for _ in 0..EVENT_LIMIT {
			offer.typing().await.unwrap();
		}
		assert!(offer.typing().await.is_err());
		assert!(
			offer
				.session
				.send(&line, "edit", &["not admitted".into()])
				.await
				.is_err()
		);
		let held = fixture.events.next().await.unwrap();
		assert!(offer.typing().await.is_err(), "handed-out typing still spends custody");
		drop(held);
		other.typing().await.unwrap();
		command(
			&fixture.commands,
			"close-typing-direct",
			Command::CloseDirect,
			vec![first.conversation().text().clone()],
		)
		.await;
		assert!(fixture.lines.receiver().typing(first, true).is_err());
		assert!(offer.typing().await.is_err());
		for _ in 0..EVENT_LIMIT - 1 {
			drop(fixture.events.next().await.unwrap());
		}
		let last = fixture.events.next().await.unwrap();
		assert_eq!(last.context.conversation(), second.conversation());
		drop(last);
		other.typing().await.unwrap();
		assert!(matches!(
			fixture.events.next().await.unwrap().content,
			Content::Typing { on: true }
		));
		dispatch.close().await.unwrap();
		task.await.unwrap().unwrap();
		drop((offer, other, line));
		fixture.close().await;
	})
	.await;
}

#[tokio::test]
async fn dropping_the_direct_event_owner_retires_hosted_producers_and_drains_queued_events() {
	deadline(async {
		let mut fixture = Fixture::new("direct-event-owner").await;
		let (dispatch, worker, mut outcomes) = fixture.dispatcher();
		let task = tokio::task::spawn_local(worker.run());
		fixture.arrival.notify("mintInboxFor").await;
		let context = published(&mut outcomes).await;
		let offer = fixture.peer.offers.recv().await.unwrap();
		let Argument::Reference(line) = offer
			.session
			.send(&offer.inbox, "dm", &["retained".into()])
			.await
			.unwrap()
		else {
			panic!("posted line");
		};
		offer.typing().await.unwrap();
		let receiver = fixture.lines.receiver();
		let (replacement, mut replacement_events) =
			DirectEvents::new(rooms_platform::HostPlatform, &mut rooms_platform::OsEntropy).unwrap();
		drop(core::mem::replace(&mut fixture.lines, replacement));
		assert!(context.current());
		assert!(receiver.typing(context.clone(), true).is_err());
		assert!(offer.typing().await.is_err());
		assert!(offer.session.send(&line, "edit", &["retired".into()]).await.is_err());
		assert!(
			offer
				.session
				.send(&offer.inbox, "dm", &["retired".into()])
				.await
				.is_err()
		);
		let said = fixture.events.next().await.unwrap();
		assert_eq!(said.line().unwrap().text, "retained");
		assert!(matches!(
			fixture.events.next().await.unwrap().content,
			Content::Typing { on: true }
		));
		assert!(
			fixture.events.next().await.is_none(),
			"held events and hosted actors cannot retain the producer channel"
		);
		fixture.lines.receiver().typing(context, false).unwrap();
		let replacement = replacement_events.next().await.unwrap();
		assert_ne!(replacement.generation, said.generation);
		assert!(
			offer.session.is_open(),
			"retiring event custody leaves shared transport open"
		);
		drop((said, replacement, line));
		dispatch.close().await.unwrap();
		task.await.unwrap().unwrap();
		drop(offer);
		fixture.close().await;
	})
	.await;
}
