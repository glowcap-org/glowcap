//! File recipients keep restricted readers after the delivery worker retires.
use super::uploads::{Trace, outcome, request};
use super::*;
use rooms_application::{content::permissions::Permission, content::session::uploads::Kind, files::CHUNK_BYTES};

pub(super) async fn run(host: &Host, owner: &managed::Session<Platform>, line: &Ref, blob: &Ref, trace: &Rc<Trace>) {
	// Content Invocation arguments borrow the active call. A real recipient's
	// CapTP delivery owns its arguments, so retained readers need that boundary.
	let recipient = Host::from_seed([132; 32]).unwrap();
	let (client, accepted) = management::connect(host, &recipient, line).await;
	let receive = |verb: &'static str, start: usize, result: Option<Ref>| {
		let trace = trace.clone();
		move |method: &str, args: &[Argument]| {
			if method != verb {
				return Err("unexpected direct file method".into());
			}
			let views = rooms_glowcap::values(&args[start..]).collect::<Vec<_>>();
			let files =
				rooms_application::room::attachment::read_exact(&views, 0).map_err(|error| format!("{error:?}"))?;
			trace
				.readers
				.borrow_mut()
				.extend(files.into_iter().map(|file| file.blob));
			trace
				.steps
				.borrow_mut()
				.push(if verb == "dm" { "direct" } else { "direct-refile" });
			Ok(result.as_ref().map_or(Argument::Void, |line| line.clone().into()))
		}
	};
	let line = client
		.session()
		.publish("direct-file-line", receive("refile", 2, None))
		.unwrap();
	client
		.session()
		.publish("direct-file-recipient", receive("dm", 1, Some(line)))
		.unwrap();
	let direct = accepted.fetch("direct-file-recipient").await.unwrap();
	let line = accepted.fetch("direct-file-line").await.unwrap();
	let coordinate = |role, slot| custody::Coordinate {
		role,
		key: custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap()),
	};
	owner
		.import(coordinate(custody::Role::DirectAccess, 1), direct.clone(), None)
		.await
		.unwrap();
	owner
		.import(coordinate(custody::Role::Line, 2), line.clone(), None)
		.await
		.unwrap();
	let intent = Intent::decode(&serde_json::json!({
		"version":1, "directories":[{"id":"directory","access":key::<custody::DirectoryAccess>(),"home":true,"nick":"peer","nickAllocation":"exact","standing":null}],
		"conversations":[{"kind":"direct","id":"room","directory":"directory","peer":"peer","access":key::<custody::DirectAccess>(),"lines":[{"id":1,"handle":coordinate(custody::Role::Line, 2).key}],"closed":false,"draft":""}],
		"invitations":[],"active":"room","standing":"","ignored":[],"keepHistory":true,"connection":"relay","archive":null,"archiveControl":null,"operators":[],"peering":[]
	}).to_string()).unwrap();
	owner.replace_workspace(&intent).await.unwrap();
	let policy = rooms_glowcap::policy::descriptor().unwrap();
	let terms = policy
		.value_for_kind(
			session::KIND,
			&[
				Permission::ObserveWorkspace.key(),
				Permission::InteractWorkspace.key(),
				Permission::ResolvePending.key(),
			],
			&[],
		)
		.unwrap();
	let (source, control) = owner
		.derive(
			terms,
			1,
			ControlPowers {
				inspect: true,
				pause: true,
				resume: true,
				revoke: true,
				..Default::default()
			},
		)
		.await
		.unwrap();
	let before = trace.steps.borrow().len();
	let (args, canonical) = request(host, &source, blob, "direct-file", Kind::Post, true).await;
	mutate(host, &source, "sendFiles", &args).await.unwrap();
	let applied = outcome(host, &source, "direct-file", &canonical).await;
	assert!(applied.files_complete && applied.line.is_some());
	assert_eq!(
		&trace.steps.borrow()[before..],
		["direct"],
		"delivery must not read or stage bytes"
	);
	let reader = trace.readers.borrow()[0].clone();
	let args_read = [0.into(), Argument::Integer(CHUNK_BYTES as i64)];
	assert_eq!(
		recipient
			.send(&reader, "read", &args_read)
			.await
			.unwrap()
			.as_bytes()
			.unwrap()
			.len(),
		CHUNK_BYTES
	);
	assert!(
		recipient
			.send(&reader, "write", &[Argument::Bytes(vec![1])])
			.await
			.is_err()
	);
	assert!(recipient.send(&reader, "discard", &[]).await.is_err());
	let before = trace.steps.borrow().len();
	assert_eq!(
		mutate(host, &source, "sendFiles", &args).await.unwrap().as_str(),
		Some("committed")
	);
	assert_eq!(trace.steps.borrow().len(), before);
	let (args, canonical) = request(host, &source, blob, "direct-refile", Kind::Refile(1), true).await;
	mutate(host, &source, "refileLine", &args).await.unwrap();
	assert!(outcome(host, &source, "direct-refile", &canonical).await.files_complete);
	assert_eq!(trace.steps.borrow().last(), Some(&"direct-refile"));
	assert_eq!(trace.readers.borrow().len(), 2);
	for action in ["pause", "resume", "revoke"] {
		let state = host.send(&control, "describe-control", &[]).await.unwrap();
		let loam::ControlDescription::Available(view) = loam::ControlDescription::read(&state).unwrap() else {
			panic!("held control");
		};
		host.send(
			&control,
			action,
			&[Argument::Bytes(view.revision.to_be_bytes().to_vec())],
		)
		.await
		.unwrap();
		let before = trace.steps.borrow().len();
		let result = recipient.send(&reader, "read", &args_read).await;
		if action == "resume" {
			assert!(result.is_ok());
		} else {
			assert!(result.is_err());
			assert_eq!(
				trace.steps.borrow().len(),
				before,
				"inactive source cannot reach a blob"
			);
		}
	}
	trace.readers.borrow_mut().clear();
	drop(reader);
	client.session().close(PendingWork::Cancel).await.unwrap();
	accepted.close(PendingWork::Cancel).await.unwrap();
	recipient.close(PendingWork::Cancel).await.unwrap();
}
