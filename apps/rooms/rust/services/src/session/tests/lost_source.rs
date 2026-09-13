//! A source that disappears during capture leaves no posted line or pending
//! effect. Restoring the source permits retry with the same operation ID.
use super::*;
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::files::CHUNK_BYTES;
use std::{cell::Cell, rc::Rc, time::Duration};
#[tokio::test]
async fn a_file_source_lost_during_capture_leaves_no_post_and_can_retry() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(40), lost_source())
				.await
				.expect("host session lost-source deadline");
		})
		.await;
}
async fn lost_source() {
	let temp = Temp::new();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let peer = DirectoryPeer::start().await;
	let running = start_session(temp.0.clone()).await;
	let parsed = glowcap::parse_sturdyref(&running.link, glowcap::CaptpVersion::V1_0).unwrap();
	let session = runtime
		.connect(&parsed.locator, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let root = session.enliven(&running.link).await.unwrap();
	let directory = join_garden_room(&session, &root, &peer).await;
	// Three chunks promised; the source answers the first and then breaks,
	// the way a tab that reloads mid-upload does.
	let size = 3 * CHUNK_BYTES;
	let reads = Rc::new(Cell::new(0u32));
	let counted = reads.clone();
	let broken = Rc::new(Cell::new(true));
	let failure = broken.clone();
	let blob = session
		.spawn(move |verb, args| {
			if verb != "read" {
				return Err("unknown file verb".into());
			}
			counted.set(counted.get() + 1);
			if failure.get() && counted.get() > 1 {
				return Err("the view holding this file is gone".into());
			}
			let length = args.get(1).and_then(Argument::as_i64).unwrap_or(0).max(0) as usize;
			Ok(Argument::Bytes(vec![7; length.min(CHUNK_BYTES)]))
		})
		.unwrap();
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	let reply = session
		.send(
			&root,
			"sendFiles",
			&send_file_args(
				snapshot.revision.get() as i64,
				"lost file",
				"lost.txt",
				size,
				blob.clone(),
			),
		)
		.await;
	let refusal = reply.expect_err("a file whose source broke is not reported as sent");
	assert!(
		refusal.to_string().contains("the view holding this file is gone"),
		"the refusal preserves the capture failure: {refusal}"
	);
	assert!(
		reads.get() == 2,
		"the session read past the first chunk before the source broke"
	);
	// Capture precedes durable preparation and any room-side mutation.
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	assert!(
		snapshot.pending_effects.as_slice().is_empty(),
		"a failed capture leaves no pending effect: {:?}",
		snapshot.pending_effects.as_slice()
	);
	let history = tokio::time::timeout(
		Duration::from_secs(5),
		session.send(
			&root,
			"readHistory",
			&["room".into(), directory.clone().into(), "garden-room".into()],
		),
	)
	.await
	.expect("history answered after failed capture")
	.unwrap();
	assert!(
		!contains_text(&history, "lost file"),
		"capture failure posted a partial line"
	);

	// The same source and operation ID become usable once all bytes can be
	// captured. This also proves admission and staging capacity were released.
	broken.set(false);
	session
		.send(
			&root,
			"sendFiles",
			&send_file_args(snapshot.revision.get() as i64, "lost file", "lost.txt", size, blob),
		)
		.await
		.unwrap();
	assert_eq!(reads.get(), 5, "retry captures once and transmits the frozen bytes");
	let row = tokio::time::timeout(
		Duration::from_secs(5),
		wait_history_row(&session, &root, &directory, "lost file"),
	)
	.await
	.expect("history contains the completed retry");
	let record = rooms_application::archive::protocol::record(&Value(&row)).unwrap();
	assert_eq!(
		record.coordinates().id.as_str(),
		Some("1"),
		"the failed capture consumed no room line"
	);
	let files = rooms_application::archive::blobs::files(&record).unwrap();
	assert_eq!(files.len(), 1, "the line keeps its file's description");
	assert!(
		files[0].blob().is_some(),
		"the completed retry retains the captured file"
	);
	stop_session(running, session).await;
	peer.close().await;
	runtime.close(PendingWork::Cancel).await.unwrap();
}
