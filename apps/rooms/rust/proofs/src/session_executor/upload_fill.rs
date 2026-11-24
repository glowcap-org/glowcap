//! A fill is bounded by its rounds and not by one total: after the post is
//! acknowledged it never pauses. The fixture advances the platform clock on each
//! append, so a fill longer than one round in total
//! completes while each round stays within it, and a round that does not
//! ends the fill with the line standing and its files incomplete.
use super::uploads::{Trace, outcome, request};
use super::*;
use rooms_application::{
	content::session::{effects::FILL_ROUND_MS, uploads::Outcome},
	failure::{Failure, FailureCode},
};
/// What the live upload does with an append.
#[derive(Clone, Copy)]
enum Room {
	/// Takes each append after half a round.
	Slow,
	/// Never answers an append.
	Silent,
	/// Refuses an append in its own words.
	Refuses,
	/// Refuses an append with a coded failure line.
	Coded,
}
const REFUSAL: &str = "the room refused the append: this file expired";
const CODED_DETAIL: &str = "the room ended this file's upload";

pub(super) async fn run(host: &Host, platform: &Platform, source: &Ref, targets: &[Ref], trace: &Rc<Trace>) {
	together(host, source, targets, trace).await;
	let slow = scenario(host, platform, source, targets, trace, Room::Slow, "slow-fill").await;
	assert!(
		slow.files_complete && slow.line.is_some() && slow.failure.is_none(),
		"a fill longer than the bound in total completes while each round keeps it: {:?}",
		slow.failure
	);
	let silent = scenario(host, platform, source, targets, trace, Room::Silent, "silent-fill").await;
	assert!(
		!silent.files_complete && silent.line.is_some(),
		"a round that makes no progress leaves the line standing with its files incomplete"
	);
	let words = format!("a round of one piece of each file did not finish within {FILL_ROUND_MS} ms");
	assert_eq!(
		silent
			.failure
			.as_ref()
			.map(|text| text.text().as_str().unwrap_or_default()),
		Some(words.as_str())
	);
	let refused = scenario(host, platform, source, targets, trace, Room::Refuses, "refused-fill").await;
	assert!(!refused.files_complete && refused.line.is_some());
	let cause = refused
		.failure
		.as_ref()
		.map(|text| text.text().as_str().unwrap_or_default().to_owned())
		.unwrap_or_default();
	assert!(
		cause.contains(REFUSAL) && !cause.contains(&words),
		"a write the room refuses ends the fill with the room's own words: {cause}"
	);
	let coded = scenario(host, platform, source, targets, trace, Room::Coded, "coded-fill").await;
	assert!(!coded.files_complete && coded.line.is_some());
	let cause = coded
		.failure
		.as_ref()
		.map(|text| text.text().as_str().unwrap_or_default().to_owned())
		.unwrap_or_default();
	let failure = Failure::parse(&cause).unwrap_or_else(|| panic!("the fill kept no code: {cause}"));
	assert_eq!(
		failure.code,
		FailureCode::UploadIncomplete,
		"the room's code survives the fill to what the sender reads: {cause}"
	);
}

/// Post one file whose live upload behaves as `room`, under the platform's
/// scenario clock, and return the outcome the receipt settled with. The receipt
/// settles committed in every scenario, so the status is read by `outcome`.
async fn scenario(
	host: &Host,
	platform: &Platform,
	source: &Ref,
	targets: &[Ref],
	trace: &Rc<Trace>,
	room: Room,
	id: &str,
) -> Outcome {
	let [files, _, blob, ..] = targets else {
		panic!("the uploads fixture restores its files resource and a blob");
	};
	let remote = Host::from_seed([134; 32]).unwrap();
	let (client, accepted) = super::management::connect(host, &remote, files).await;
	let (clock, _) = tokio::sync::watch::channel(0);
	let parked = Rc::new(std::cell::RefCell::new(None));
	let upload = accepted
		.spawn_owned({
			let parked = parked.clone();
			let clock = clock.clone();
			let host = host.clone();
			move |verb, args| match (verb.ok_or("fixture requires a method")?, room) {
				("write", Room::Refuses) => Err(REFUSAL.into()),
				("write", Room::Coded) => Err(FailureCode::UploadIncomplete.line(CODED_DETAIL)),
				("write", _) => {
					let [Argument::Bytes(_)] = args else {
						return Err("invalid append".into());
					};
					if matches!(room, Room::Silent) {
						*parked.borrow_mut() = Some(host.defer_turn().map_err(|error| error.to_string())?);
						clock.send_modify(|now| *now += FILL_ROUND_MS);
					} else {
						clock.send_modify(|now| *now += FILL_ROUND_MS / 2);
					}
					Ok(Argument::Void)
				}
				_ => Err("unexpected live upload call".into()),
			}
		})
		.unwrap();
	host.send(files, "configureLiveUpload", &[upload.into()]).await.unwrap();
	trace.deferred.set(true);
	let (args, canonical) = request(
		host,
		source,
		blob,
		id,
		rooms_application::content::session::uploads::Kind::Post,
		true,
	)
	.await;
	*platform.clock_ms.borrow_mut() = Some(clock.clone());
	super::mutate(host, source, "sendFiles", &args).await.unwrap();
	let settled = outcome(host, source, id, &canonical).await;
	platform.clock_ms.borrow_mut().take();
	if matches!(room, Room::Slow) {
		assert!(*clock.borrow() > FILL_ROUND_MS, "the fill crossed a whole round");
	}
	trace.deferred.set(false);
	// The settled receipt holds one of the session's few places.
	let released = host
		.send(source, "release-effect", &[id.into(), canonical.as_str().into()])
		.await
		.unwrap();
	assert_eq!(released.as_str(), Some("released"));
	client.session().close(PendingWork::Cancel).await.unwrap();
	accepted.close(PendingWork::Cancel).await.unwrap();
	remote.close(PendingWork::Cancel).await.unwrap();
	settled
}

/// Two files are filled a chunk of each in turn, so the room's lease on the
/// second renews while the first is still filling.
async fn together(host: &Host, source: &Ref, targets: &[Ref], trace: &Rc<Trace>) {
	use rooms_application::{
		content::session::uploads::{Description, Intent as UploadIntent, Kind},
		fields::List,
		files::{CHUNK_BYTES, FileDescription},
	};
	let (blob, other) = (&targets[2], &targets[4]);
	let size = super::uploads::FIXTURE_SIZE;
	let base = host.send(source, "snapshot", &[]).await.unwrap().as_list().unwrap()[0]
		.as_i64()
		.unwrap();
	let description = FileDescription::parse("file.bin", "application/octet-stream", size as u64, 0, 0).unwrap();
	let intent = UploadIntent {
		upload: Kind::Post,
		operation: "together".into(),
		base: base as u64,
		conversation: "room".into(),
		caption: "caption".into(),
		previews: "[]".into(),
		keep: List::default(),
		files: List::new(vec![
			Description::from_file(&description),
			Description::from_file(&description),
		])
		.unwrap(),
	};
	let mut args = vec![
		"together".into(),
		Argument::Integer(base),
		"room".into(),
		"caption".into(),
		"[]".into(),
	];
	for blob in [blob, other] {
		args.extend([
			"file".into(),
			"file.bin".into(),
			"application/octet-stream".into(),
			Argument::Integer(size as i64),
			blob.clone().into(),
			0.into(),
			0.into(),
		]);
	}
	let before = trace.offsets.borrow().len();
	super::mutate(host, source, "sendFiles", &args).await.unwrap();
	let canonical = intent.canonical().unwrap();
	let settled = outcome(host, source, "together", &canonical).await;
	assert!(
		settled.files_complete && settled.line.is_some(),
		"{:?}",
		settled.failure
	);
	assert_eq!(
		trace.offsets.borrow()[before..],
		[0, 0, CHUNK_BYTES, CHUNK_BYTES, 2 * CHUNK_BYTES, 2 * CHUNK_BYTES],
		"each round reads one chunk of every unfinished file"
	);
	let released = host
		.send(
			source,
			"release-effect",
			&["together".into(), canonical.as_str().into()],
		)
		.await
		.unwrap();
	assert_eq!(released.as_str(), Some("released"));
}
