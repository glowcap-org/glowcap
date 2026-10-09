//! Real foreign reads use viewer admission and the retained original callback.
use super::*;
use rooms_glowcap::client::workspace::Workspace;

pub(super) async fn run(
	host: &Host,
	owner: &managed::Session<Platform>,
	platform: &Platform,
	source: &Ref,
	control: &Ref,
	callback: &Ref,
) {
	let local = Workspace::local(host.clone(), platform.clone(), source.clone());
	let _local_reader = local.activity_reader().await.expect("local activity reader");
	let viewer = Host::from_seed([174; 32]).unwrap();
	let (client, accepted) = management::connect(host, &viewer, source).await;
	let fetched = management::bootstrap(&client).await;
	let remote = Workspace::new(client, fetched.reference().clone());
	let reader = remote.activity_reader().await.unwrap();
	let blob = host
		.spawn(|verb, args| {
			if verb != "read" || !matches!(args, [Argument::Integer(0), Argument::Integer(4)]) {
				return Err("invalid blob read".into());
			}
			Ok(Argument::Bytes(vec![1, 2, 3, 4]))
		})
		.unwrap();
	host.send(
		callback,
		"notify",
		&[
			"member".into(),
			"Retained activity".into(),
			"file".into(),
			"retained.bin".into(),
			"application/octet-stream".into(),
			4.into(),
			blob.into(),
			0.into(),
			0.into(),
		],
	)
	.await
	.unwrap();
	let reply: serde_json::Value = serde_json::from_str(&reader.read("", false).await.unwrap()).unwrap();
	let token = reply["cursor"].as_str().unwrap();
	assert!(reply["data"].as_str().unwrap().contains("Retained activity"));
	assert_eq!(reply["files"][0]["name"], "retained.bin");
	let file = remote.activity_file(token, 0).await.unwrap();
	assert_eq!(
		viewer
			.send(&file, "read", &[0.into(), 4.into()])
			.await
			.unwrap()
			.as_bytes()
			.unwrap(),
		[1, 2, 3, 4]
	);
	assert!(viewer.send(&file, "write", &[]).await.is_err());
	let delivered = owner
		.activity()
		.receive_after(host, platform.clone(), 0, false)
		.await
		.unwrap();
	assert!(delivered.event.is_some());
	assert!(!delivered.unavailable);
	assert_eq!(owner.activity().token(delivered.cursor).unwrap(), token);
	// A numerically equal cursor from another lifetime must never retarget.
	let mut stale = token.as_bytes().to_vec();
	stale[0] = if stale[0] == b'0' { b'1' } else { b'0' };
	assert!(reader.read(std::str::from_utf8(&stale).unwrap(), false).await.is_err());
	publication_results::lifecycle(host, control, "pause").await;
	assert!(
		reader.read(token, false).await.is_err(),
		"returned reader retains viewer admission"
	);
	assert!(
		viewer.send(&file, "read", &[0.into(), 4.into()]).await.is_err(),
		"retained file checks paused source"
	);
	let unavailable = owner
		.activity()
		.receive_after(host, platform.clone(), 0, false)
		.await
		.unwrap();
	assert!(unavailable.unavailable, "source pause invalidates queued presentation");
	assert!(unavailable.event.is_none());
	publication_results::lifecycle(host, control, "resume").await;
	let reply: serde_json::Value = serde_json::from_str(&reader.read("", false).await.unwrap()).unwrap();
	assert_eq!(reply["cursor"], token, "resumed source preserves event identity");
	assert_eq!(
		viewer
			.send(&file, "read", &[0.into(), 4.into()])
			.await
			.unwrap()
			.as_bytes()
			.unwrap(),
		[1, 2, 3, 4]
	);
	viewer.close(PendingWork::Cancel).await.unwrap();
	drop((file, reader, remote, fetched, accepted));
}
