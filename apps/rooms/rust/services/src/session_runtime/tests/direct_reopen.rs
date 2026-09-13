//! Local reopening advertises fresh authority before route readiness.
use super::*;

#[tokio::test]
async fn local_reopen_refreshes_its_inbox_without_another_remote_request() {
	deadline(async {
		let mut fixture = Fixture::new("reopened-inbox").await;
		let (dispatch, worker, mut outcomes) = fixture.dispatcher();
		let task = tokio::task::spawn_local(worker.run());
		fixture.arrival.notify("mintInboxFor").await;
		let original = published(&mut outcomes).await;
		let old = fixture.peer.offers.recv().await.unwrap();
		command(
			&fixture.commands,
			"close",
			Command::CloseDirect,
			vec![original.conversation().text().clone()],
		)
		.await;
		assert!(old.typing().await.is_err());
		command(
			&fixture.commands,
			"reopen",
			Command::OpenDirect,
			vec![
				json!({"kind":"direct", "id": original.conversation().text().as_str().unwrap(),
                "directory": original.directory().text().as_str().unwrap(), "peer":"bob",
                "peerRegistrationId": original.registration().as_str(), "closed":false, "draft":""})
				.to_string()
				.into(),
			],
		)
		.await;
		let current = fixture
			.runtime
			.intended_direct(original.conversation().text().as_str().unwrap())
			.unwrap();
		assert!(!current.same_context(&original));
		fixture.peer.delay_offer.set(true);
		let mut opening = Box::pin(dispatch.ensure(&current).unwrap().wait());
		let mut fresh = tokio::select! {
			offer = fixture.peer.offers.recv() => offer.unwrap(),
			result = &mut opening => panic!("route answered before its fresh inbox was acknowledged: {result:?}"),
		};
		assert_ne!(fresh.inbox, old.inbox);
		assert!(old.typing().await.is_err(), "reopening cannot restore the old inbox");
		fresh.typing().await.unwrap();
		fresh.answer.as_mut().unwrap().fulfill(&Argument::Void).unwrap();
		opening.await.unwrap();
		dispatch.ensure(&current).unwrap().wait().await.unwrap();
		assert!(
			matches!(fixture.peer.offers.try_recv(), Err(mpsc::error::TryRecvError::Empty)),
			"an acknowledged current inbox is reused"
		);
		dispatch.close().await.unwrap();
		task.await.unwrap().unwrap();
		drop((fresh, old));
		fixture.close().await;
	})
	.await;
}
