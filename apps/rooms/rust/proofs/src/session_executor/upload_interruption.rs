//! A committed append has one retained observation across worker cancellation.
use super::uploads::{Trace, outcome, request};
use super::*;
use std::cell::RefCell;
pub(super) async fn run(
	host: &Host,
	owner: &managed::Session<Platform>,
	platform: &Platform,
	files: &Ref,
	source: &Ref,
	blob: &Ref,
	trace: &Rc<Trace>,
) {
	let remote = Host::from_seed([132; 32]).unwrap();
	let (client, accepted) = super::management::connect(host, &remote, files).await;
	let paused = Rc::new(RefCell::new(None::<glowcap::Resolver>));
	let upload = accepted
		.spawn_owned({
			let paused = paused.clone();
			let trace = trace.clone();
			let host = host.clone();
			let mut first = true;
			move |verb, args| match verb.ok_or("fixture requires a method")? {
				"write" => {
					let [Argument::Bytes(bytes)] = args else {
						return Err("invalid append".into());
					};
					assert!(bytes.iter().all(|byte| *byte == 7));
					trace.steps.borrow_mut().push("write");
					trace.writes.borrow_mut().push(bytes.len());
					if first {
						first = false;
						*paused.borrow_mut() = Some(host.defer_turn().map_err(|error| error.to_string())?);
					}
					Ok(Argument::Void)
				}
				"discard" => {
					trace.steps.borrow_mut().push("discard");
					Ok(Argument::Void)
				}
				_ => Err("unexpected live upload call".into()),
			}
		})
		.unwrap();
	host.send(files, "configureLiveUpload", &[upload.into()]).await.unwrap();
	trace.deferred.set(true);
	let writes = trace.writes.borrow().len();
	let (args, canonical) = request(
		host,
		source,
		blob,
		"interrupted-append",
		rooms_application::content::session::uploads::Kind::Post,
		true,
	)
	.await;
	super::mutate(host, source, "sendFiles", &args).await.unwrap();
	while paused.borrow().is_none() {
		environment::yield_turn().await;
	}
	assert_eq!(
		trace.writes.borrow().len(),
		writes + 1,
		"append took effect before interruption"
	);
	platform.tasks.borrow().last().unwrap().abort();
	for _ in 0..3 {
		environment::yield_turn().await;
	}
	owner.resume_pending().unwrap();
	paused.borrow_mut().take().unwrap().fulfill(&Argument::Void).unwrap();
	let settled = outcome(host, source, "interrupted-append", &canonical).await;
	assert!(settled.files_complete && settled.line.is_some());
	assert_eq!(
		&trace.writes.borrow()[writes..],
		&[
			rooms_application::files::CHUNK_BYTES,
			rooms_application::files::CHUNK_BYTES,
			17
		],
		"the exact first acknowledgement resumes without replaying its append"
	);
	let before = trace.steps.borrow().len();
	assert_eq!(
		super::mutate(host, source, "sendFiles", &args).await.unwrap().as_str(),
		Some("committed")
	);
	assert_eq!(trace.steps.borrow().len(), before);
	trace.deferred.set(false);
	assert!(host.unpublish("management-bootstrap").unwrap());
	client.session().close(PendingWork::Cancel).await.unwrap();
	accepted.close(PendingWork::Cancel).await.unwrap();
	remote.close(PendingWork::Cancel).await.unwrap();
}
