//! Independent user actions must not become identical receipt retries.
use std::{future::Future, task::Poll};

pub async fn run(locator: &glowcap::Locator, name: &str) {
	let board = crate::task_board::Board::join(locator, name).await.unwrap();
	let before = board.lists().await.unwrap()[0].tasks.len();
	let (left, right) = tokio::join!(board.add("rust same"), board.add("rust same"));
	left.unwrap();
	right.unwrap();
	assert_eq!(board.lists().await.unwrap()[0].tasks.len(), before + 2);
	let (left, right) = tokio::join!(board.add("rust left"), board.add("rust right"));
	left.unwrap();
	right.unwrap();
	assert_eq!(board.lists().await.unwrap()[0].tasks.len(), before + 4);
	let oversized = "x".repeat(4097);
	let (refused, resumed) = tokio::join!(board.add(&oversized), board.add("rust after refusal"));
	assert!(refused.is_err());
	resumed.unwrap();
	let mut leader = Box::pin(board.add("rust cancellation leader"));
	let mut cancelled = Box::pin(board.add("rust cancelled waiter"));
	std::future::poll_fn(|cx| {
		assert!(leader.as_mut().poll(cx).is_pending());
		assert!(cancelled.as_mut().poll(cx).is_pending());
		Poll::Ready(())
	})
	.await;
	drop(cancelled);
	leader.await.unwrap();
	let (added, read) = tokio::join!(board.add("rust after cancellation"), board.lists());
	added.unwrap();
	read.unwrap();
	let tasks = &board.lists().await.unwrap()[0].tasks;
	assert_eq!(tasks.len(), before + 7);
	assert!(!tasks.iter().any(|text| text == "rust cancelled waiter"));
	let mut acquiring = Box::pin(board.add("rust cancelled acquisition"));
	std::future::poll_fn(|cx| {
		assert!(acquiring.as_mut().poll(cx).is_pending());
		Poll::Ready(())
	})
	.await;
	drop(acquiring);
	board.add("rust after acquisition cancellation").await.unwrap();
	let mut submitted = Box::pin(board.add("rust submitted then cancelled"));
	std::future::poll_fn(|cx| {
		assert!(submitted.as_mut().poll(cx).is_pending());
		Poll::Ready(())
	})
	.await;
	// Drive the sequence reply without polling the mutation future. Its next
	// poll submits mutate synchronously, then waits for the remote reply.
	board.lists().await.unwrap();
	std::future::poll_fn(|cx| {
		assert!(submitted.as_mut().poll(cx).is_pending());
		Poll::Ready(())
	})
	.await;
	drop(submitted);
	// This is a distinct action with equal text, never a retry of the unknown
	// outcome. Its query must follow the prior admitted mutation at the server.
	board.add("rust submitted then cancelled").await.unwrap();
	let tasks = &board.lists().await.unwrap()[0].tasks;
	assert_eq!(tasks.len(), before + 10);
	assert_eq!(
		tasks
			.iter()
			.filter(|text| *text == "rust submitted then cancelled")
			.count(),
		2
	);
	assert!(!tasks.iter().any(|text| text == "rust cancelled acquisition"));
	board.leave().await.unwrap();
}
