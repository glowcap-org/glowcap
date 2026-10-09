//! Control custody and wakeups are independent of a model consumer.
use super::*;

#[test]
fn acquisition_socket_preserves_document_text_and_rejects_unknown_fields() {
	let intent = serde_json::to_string(&rooms_application::content::session::workspace::Intent::empty())
		.unwrap()
		.replace("\"standing\":\"\"", "\"standing\":\"\\ud800\"");
	for fields in [
		"\"kind\":\"workspace\",\"imports\":[]".to_owned(),
		"\"kind\":\"result\",\"operation\":\"original\",\"command_base\":0,\"name\":\"say\",\"args\":[],\"mappings\":[]".to_owned(),
	] {
		let body = format!("{{\"verb\":\"acquire\",\"id\":\"stable\",\"request\":{{{fields},\"base\":0,\"releases\":[],\"source\":null,\"intent\":{intent}}}}}");
		let request: RequestBody = serde_json::from_str(&body).unwrap();
		let RequestBody::Acquire { request, .. } = request else { panic!("acquisition required") };
		let encoded = serde_json::to_string(&request).unwrap();
		assert!(encoded.contains("\\ud800"), "socket replaced document text: {encoded}");
		let extra = body.replacen("\"base\":0", "\"unexpected\":true,\"base\":0", 1);
		assert!(serde_json::from_str::<RequestBody>(&extra).is_err());
	}
}

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
	assert!(next.worker.pending(0).await.unwrap()["gap"].is_null());
	drop(next.close().await.unwrap());
	std::fs::remove_dir_all(path).unwrap();
}

#[tokio::test(flavor = "current_thread")]
async fn only_committed_changes_wake_inbox_consumers() {
	let path = path();
	let owner = worker::Owner::open(path.clone()).await.unwrap();
	let mut updates = owner.worker.updates();
	owner.worker.event(json!({"text":"hello"})).await.unwrap();
	tokio::time::timeout(Duration::from_secs(2), updates.changed())
		.await
		.unwrap()
		.unwrap();
	let pending = owner.worker.pending(0).await.unwrap();
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
	assert_eq!(owner.worker.pending(0).await.unwrap()["remaining"], 0);
	drop(owner.close().await.unwrap());
	std::fs::remove_dir_all(path).unwrap();
}

#[tokio::test(flavor = "current_thread")]
async fn inbox_pages_survive_acknowledgment_and_restart_without_acknowledging_delivery() {
	let path = path();
	let owner = worker::Owner::open(path.clone()).await.unwrap();
	for id in 1..=130 {
		assert_eq!(
			owner.worker.event(json!({"text":format!("line-{id}")})).await.unwrap(),
			id
		);
	}
	let first = owner.worker.pending(0).await.unwrap();
	assert_eq!(first["pending"].as_array().unwrap().len(), 64);
	assert_eq!(first["more"], true);
	let second = owner.worker.pending(64).await.unwrap();
	assert_eq!(second["cursor"], first["cursor"], "paging is not a journal mutation");
	assert_eq!(second["pending"][0]["id"], 65);
	assert_eq!(second["pending"][63]["id"], 128);
	assert_eq!(second["remaining"], 130, "reading must not acknowledge");
	owner.worker.ack(vec![1, 64, 65, 129]).await.unwrap();
	let second = owner.worker.pending(64).await.unwrap();
	assert_eq!(
		second["pending"][0]["id"], 66,
		"acknowledgment must not shift the page position"
	);
	assert_eq!(second["pending"][63]["id"], 130);
	assert_eq!(second["more"], false);
	drop(owner.close().await.unwrap());
	let owner = worker::Owner::open(path.clone()).await.unwrap();
	let replay = owner.worker.pending(0).await.unwrap();
	assert_eq!(replay["pending"][0]["id"], 2);
	assert_eq!(replay["remaining"], 126);
	assert_eq!(owner.worker.pending(128).await.unwrap()["pending"][0]["id"], 130);
	assert_eq!(owner.worker.event(json!({"text":"after-restart"})).await.unwrap(), 131);
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
			let mut peer = crate::session::Peer::open(config, Rc::new(|_| {})).await.unwrap();
			let mut control = Control::open(&peer, Rc::new(|_| {})).await.unwrap();
			assert!(Control::open(&peer, Rc::new(|_| {})).await.is_err());
			assert!(UnixStream::connect(path.join("control.sock")).await.is_ok());
			control.feed.inbox.event(json!({"text":"first"})).await.unwrap();
			let first = control.pending(0).await.unwrap();
			let mut next = Box::pin(control.execute(RequestBody::Tick {
				wait: 2,
				after: first["cursor"].as_u64(),
				after_id: 1,
			}));
			assert!(
				tokio::time::timeout(Duration::from_millis(20), &mut next)
					.await
					.is_err(),
				"an unchanged pending batch should wait for a committed change"
			);
			control.feed.inbox.event(json!({"text":"second"})).await.unwrap();
			assert_eq!(next.await.unwrap()["remaining"], 2);
			for id in 3..=130 {
				control
					.feed
					.inbox
					.event(json!({"text":format!("line-{id}")}))
					.await
					.unwrap();
			}
			let first = control.pending(0).await.unwrap();
			let second = tokio::time::timeout(
				Duration::from_secs(1),
				control.execute(RequestBody::Tick {
					wait: 30,
					after: first["cursor"].as_u64(),
					after_id: 64,
				}),
			)
			.await
			.unwrap()
			.unwrap();
			assert_eq!(
				second["pending"][0]["id"], 65,
				"a retained page must drain without a new wake"
			);
			assert_eq!(second["cursor"], first["cursor"]);
			assert_eq!(second["more"], true);
			control.detach().await;
			peer.close().await.unwrap();
			control.close().await.unwrap();
			assert!(!path.join("control.sock").exists());
			std::fs::remove_dir_all(path).unwrap();
		})
		.await;
}
