//! Control custody and wakeups are independent of a model consumer.
use super::*;

fn path() -> PathBuf {
	static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
	std::env::temp_dir().join(format!(
		"rooms-control-{}-{}",
		std::process::id(),
		NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
	))
}

#[tokio::test(flavor = "current_thread")]
async fn retired_worker_keeps_custody_until_socket_cleanup_finishes() {
	let path = path();
	let owner = worker::Owner::open(path.clone()).await.unwrap();
	assert!(worker::Owner::open(path.clone()).await.is_err());
	let retired = owner.close().await.unwrap();
	assert!(
		worker::Owner::open(path.clone()).await.is_err(),
		"retirement must retain the lease for socket cleanup"
	);
	drop(retired);
	let next = worker::Owner::open(path.clone()).await.unwrap();
	assert!(next.worker.pending().await.unwrap()["gap"].is_null());
	drop(next.close().await.unwrap());
	std::fs::remove_dir_all(path).unwrap();
}

#[tokio::test(flavor = "current_thread")]
async fn only_committed_changes_wake_inbox_consumers() {
	let path = path();
	let owner = worker::Owner::open(path.clone()).await.unwrap();
	let mut updates = owner.worker.updates();
	owner.worker.event(json!({"text":"hello"})).unwrap();
	tokio::time::timeout(Duration::from_secs(2), updates.changed())
		.await
		.unwrap()
		.unwrap();
	let pending = owner.worker.pending().await.unwrap();
	assert_eq!(pending["cursor"], 1);
	assert_eq!(pending["pending"][0]["text"], "hello");
	assert!(
		tokio::time::timeout(Duration::from_millis(20), updates.changed())
			.await
			.is_err(),
		"reading an unchanged inbox must not generate another wake"
	);
	owner.worker.ack(vec![1]).await.unwrap();
	tokio::time::timeout(Duration::from_secs(2), updates.changed())
		.await
		.unwrap()
		.unwrap();
	assert_eq!(owner.worker.pending().await.unwrap()["remaining"], 0);
	drop(owner.close().await.unwrap());
	std::fs::remove_dir_all(path).unwrap();
}

#[tokio::test(flavor = "current_thread")]
async fn a_second_control_cannot_remove_the_live_socket() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let path = path();
			let config = crate::session::Config::parse(
				[format!("--state={}", path.display()), "--transport=tcp".into()],
				|_| None,
			)
			.unwrap()
			.unwrap();
			let peer = crate::session::Peer::open(config, Rc::new(|_| {})).await.unwrap();
			let control = Control::open(&peer, Rc::new(|_| {})).await.unwrap();
			assert!(Control::open(&peer, Rc::new(|_| {})).await.is_err());
			assert!(UnixStream::connect(path.join("control.sock")).await.is_ok());
			control.feed.inbox.event(json!({"text":"first"})).unwrap();
			let first = control.pending().await.unwrap();
			let mut next = Box::pin(control.execute(RequestBody::Tick {
				wait: 2,
				after: first["cursor"].as_u64(),
			}));
			assert!(
				tokio::time::timeout(Duration::from_millis(20), &mut next)
					.await
					.is_err(),
				"an unchanged pending batch should wait for a committed change"
			);
			control.feed.inbox.event(json!({"text":"second"})).unwrap();
			assert_eq!(next.await.unwrap()["remaining"], 2);
			control.detach();
			peer.close().await.unwrap();
			control.close().await.unwrap();
			assert!(!path.join("control.sock").exists());
			std::fs::remove_dir_all(path).unwrap();
		})
		.await;
}
