use super::*;
use std::cell::Cell;

#[tokio::test]
async fn incoming_views_share_one_read_and_withdraw_only_the_final_selection() {
	deadline(async {
		let mut fixture = Fixture::new("direct-media").await;
		let (dispatch, worker, mut outcomes) = fixture.dispatcher();
		let task = tokio::task::spawn_local(worker.run());
		fixture.arrival.notify("mintInboxFor").await;
		published(&mut outcomes).await;
		let offer = fixture.peer.offers.recv().await.unwrap();
		let reads = Rc::new(Cell::new(0));
		let calls = reads.clone();
		let blob = offer
			.session
			.spawn_owned(move |verb, _| {
				assert_eq!(verb, "read");
				calls.set(calls.get() + 1);
				if calls.get() != 1 {
					return Err("one-pass source exhausted".into());
				}
				Ok(Argument::Bytes(vec![9]))
			})
			.unwrap();
		let arguments = |name: &str| {
			vec![
				"caption".into(),
				"file".into(),
				name.into(),
				"text/plain".into(),
				1.into(),
				blob.clone().into(),
				0.into(),
				0.into(),
			]
		};
		let mut lines = Vec::new();
		let mut views = Vec::new();
		for name in ["first", "renamed"] {
			let Argument::Reference(line) = offer.session.send(&offer.inbox, "dm", &arguments(name)).await.unwrap()
			else {
				panic!("direct line")
			};
			let event = fixture.events.next().await.unwrap();
			assert!(
				event.recording.unwrap().is_none(),
				"media capture is independent of recording"
			);
			assert_eq!(event.files[0].description().name(), name);
			assert_eq!(event.files[0].read(0, 1).await.unwrap(), [9]);
			views.push(event.files[0].clone());
			lines.push(line);
		}
		assert_eq!(reads.get(), 1);
		// Duplicate selection indices refuse before media or event admission.
		assert!(
			offer
				.session
				.send(&lines[1], "refile", &["invalid".into(), 0.into(), 0.into()])
				.await
				.is_err()
		);
		offer.session.send(&lines[0], "withdraw", &[]).await.unwrap();
		assert!(fixture.events.next().await.unwrap().files.is_empty());
		assert_eq!(
			views[0].read(0, 1).await.unwrap(),
			[9],
			"a sibling line still selects these bytes"
		);
		for verb in ["edit", "refile"] {
			let args = if verb == "refile" {
				vec!["retained".into(), 0.into()]
			} else {
				vec!["retained".into()]
			};
			offer.session.send(&lines[1], verb, &args).await.unwrap();
			let event = fixture.events.next().await.unwrap();
			assert_eq!(event.files[0].read(0, 1).await.unwrap(), [9]);
		}
		let admitted = views[1].materialize();
		offer.session.send(&lines[1], "withdraw", &[]).await.unwrap();
		assert!(fixture.events.next().await.unwrap().files.is_empty());
		for view in &views {
			assert!(view.read(0, 1).await.is_err());
		}
		assert_eq!(admitted.await.unwrap().read(0, 1).unwrap(), [9]);
		assert_eq!(reads.get(), 1);
		dispatch.close().await.unwrap();
		task.await.unwrap().unwrap();
		drop((offer, blob, lines, views));
		fixture.close().await;
	})
	.await;
}

#[tokio::test]
async fn direct_media_shutdown_retains_pending_cancellation_until_observed() {
	deadline(async {
		let mut fixture = Fixture::new("direct-media-close").await;
		let (dispatch, worker, mut outcomes) = fixture.dispatcher();
		let task = tokio::task::spawn_local(worker.run());
		fixture.arrival.notify("mintInboxFor").await;
		published(&mut outcomes).await;
		let offer = fixture.peer.offers.recv().await.unwrap();
		let answer = Rc::new(RefCell::new(None));
		let pending = answer.clone();
		let blob = offer
			.session
			.spawn_owned(move |_, _| {
				*pending.borrow_mut() = Some(
					glowcap::current_session()
						.unwrap()
						.unwrap()
						.host()
						.defer_turn()
						.unwrap(),
				);
				Ok(Argument::Void)
			})
			.unwrap();
		offer
			.session
			.send(
				&offer.inbox,
				"dm",
				&[
					"pending".into(),
					"file".into(),
					"pending".into(),
					"text/plain".into(),
					1.into(),
					blob.clone().into(),
					0.into(),
					0.into(),
				],
			)
			.await
			.unwrap();
		let event = fixture.events.next().await.unwrap();
		let reader = event.files[0].materialize();
		while answer.borrow().is_none() {
			tokio::task::yield_now().await;
		}
		let mut closing = Box::pin(fixture.lines.close_files());
		assert!(
			closing
				.as_mut()
				.poll(&mut Context::from_waker(Waker::noop()))
				.is_pending()
		);
		drop(closing);
		assert!(
			offer.typing().await.is_err(),
			"cancelled observation does not reopen admission"
		);
		fixture.lines.close_files().await.unwrap();
		assert!(reader.await.is_err());
		assert!(fixture.events.next().await.is_none());
		answer
			.borrow_mut()
			.take()
			.unwrap()
			.break_with("source ended after receiver shutdown")
			.unwrap();
		assert!(offer.session.is_open());
		dispatch.close().await.unwrap();
		task.await.unwrap().unwrap();
		drop((offer, blob, event));
		fixture.close().await;
	})
	.await;
}
