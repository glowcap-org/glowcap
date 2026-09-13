//! Shared media custody while a native room is still receiving file bytes.
use rooms_application::files::{CHUNK_BYTES, FileDescription};
use rooms_browser::platform::Platform;
use rooms_glowcap::client::room::{Messages, Room};
use rooms_runtime::files::media::Media;

pub async fn exercise(room: &Room<Platform>, messages: &mut Messages) {
	let bytes: Vec<u8> = (0..CHUNK_BYTES + 17).map(|i| (i % 251) as u8).collect();
	let description = FileDescription::new(
		"wasm-capture".into(),
		"application/octet-stream".into(),
		bytes.len() as u64,
		0,
		0,
	)
	.unwrap();
	let mut upload = room.stage(description).await.unwrap();
	let line = room.post_files("shared media capture").await.unwrap().unwrap();
	let message = loop {
		let message = messages.next().await.unwrap().unwrap();
		if message.text == "shared media capture" && !message.attachments.is_empty() {
			break message;
		}
	};
	let platform = room.client().platform().clone();
	let mut media = Media::new(platform);
	let mut previous = Vec::new();
	let first = media
		.receive(
			1u64,
			room.client().session(),
			message.attachments.clone(),
			&mut previous,
		)
		.unwrap();
	let sibling = media
		.receive(2u64, room.client().session(), message.attachments, &mut Vec::new())
		.unwrap();
	// Two lines lease the same capture.
	let read = first[0].materialize();
	media.forget(|line| *line == 1);
	let sibling_read = sibling[0].materialize();
	media.forget(|line| *line == 2);
	assert!(first[0].materialize().await.is_err());
	// Both admitted readers survive final selection retirement and late bytes.
	let writing = async {
		for chunk in bytes.chunks(CHUNK_BYTES) {
			upload.write(chunk.to_vec()).await.unwrap();
		}
	};
	let ((), first, sibling) = tokio::join!(writing, read, sibling_read);
	let (first, sibling) = (first.unwrap(), sibling.unwrap());
	let a = first.span(0, CHUNK_BYTES).unwrap();
	let b = sibling.span(0, CHUNK_BYTES).unwrap();
	assert_eq!(a.as_ref().as_ptr(), b.as_ref().as_ptr(), "one shared materialization");
	assert_eq!(a.as_ref(), &bytes[..CHUNK_BYTES]);
	assert_eq!(first.read(CHUNK_BYTES as u64, 17).unwrap(), &bytes[CHUNK_BYTES..]);
	media.close().await.unwrap();
	assert_eq!(first.read(0, 3).unwrap(), &bytes[..3]);
	line.withdraw().await.unwrap();
}
