use super::*;
use glowcap::{tcp, Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig};
use std::time::Duration;
#[tokio::test]
async fn session_service_sends_refiles_and_reads_archived_attachments() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(40), files())
				.await
				.expect("native session file deadline");
		})
		.await;
}
async fn files() {
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
	let payload = b"owned by the durable session";
	let blob = session.spawn(move |verb, args| read_blob(payload, verb, args)).unwrap();
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"sendFiles",
			&send_file_args(
				snapshot.revision.get() as i64,
				"durable file",
				"proof.txt",
				payload.len(),
				blob,
			),
		)
		.await
		.unwrap();
	let row = wait_history_row(&session, &root, &directory, "durable file").await;
	let reader = session
		.send(&root, "archivedAttachment", &[row.clone(), Argument::Integer(0)])
		.await
		.unwrap();
	let Argument::Reference(reader) = reader else {
		panic!("archivedAttachment answers a file capability, got {reader:?}");
	};
	let bytes = session
		.send(
			&reader,
			"read",
			&[Argument::Integer(0), Argument::Integer(payload.len() as i64)],
		)
		.await
		.unwrap();
	assert_eq!(bytes.as_bytes(), Some(payload.as_slice()), "archived attachment bytes");
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"refileLine",
			&[
				"refile-operation".into(),
				Argument::Integer(snapshot.revision.get() as i64),
				"garden-room".into(),
				Argument::Integer(1),
				"refiled caption".into(),
			],
		)
		.await
		.unwrap();
	wait_history_row(&session, &root, &directory, "refiled caption").await;
	stop_session(running, session).await;
	peer.close().await;
	runtime.close(PendingWork::Cancel).await.unwrap();
}
fn read_blob(payload: &'static [u8], verb: &str, args: &[Argument]) -> Result<Argument, String> {
	if verb != "read" {
		return Err("unknown file verb".into());
	}
	let offset = args.first().and_then(Argument::as_i64).unwrap_or(0).max(0) as usize;
	let length = args.get(1).and_then(Argument::as_i64).unwrap_or(0).max(0) as usize;
	let end = offset.saturating_add(length).min(payload.len());
	Ok(Argument::Bytes(payload.get(offset..end).unwrap_or(&[]).to_vec()))
}
