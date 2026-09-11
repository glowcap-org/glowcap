use super::*;
use crate::session_state::{OrdinaryStatus, ResultStatus};
use rooms_application::session::{
	checkpoint::{commands::results, Checkpoint},
	state::{Inspection, Outcome},
};
use rooms_glowcap::routes::CheckpointRoutes;
async fn send<T>(admission: Result<Admission<T>, AdmissionError>) -> Result<T, String> {
	admission.unwrap().send().unwrap().wait().await
}
#[tokio::test]
async fn ordinary_inspections_remain_owner_bound_across_interleaved_commands() {
	let first = Temp::new();
	let second = Temp::new();
	let (a, aw) = SessionCommands::open(owner(&first.0).await, crate::client::Deadline)
		.await
		.unwrap();
	let (b, bw) = SessionCommands::open(owner(&second.0).await, crate::client::Deadline)
		.await
		.unwrap();
	let (ae, at) = events();
	let (be, bt) = events();
	let (ar, br, ()) = tokio::join!(aw.run(ae), bw.run(be), async {
		let Inspection::New(wrong_owner) = send(a.inspect_ordinary(text("say"), 0, "[\"say\"]".into()))
			.await
			.unwrap()
		else {
			panic!("fresh inspection")
		};
		assert!(send(b.prepare_inspected(wrong_owner, "[\"say\"]".into()))
			.await
			.is_err());
		let Inspection::New(inspection) = send(a.inspect_ordinary(text("say"), 0, "[\"say\"]".into()))
			.await
			.unwrap()
		else {
			panic!("fresh inspection")
		};
		assert_eq!(
			command(&a, "standing", 0, Command::SetStanding, vec!["away".into()])
				.await
				.unwrap(),
			1
		);
		assert!(matches!(
			send(a.prepare_inspected(inspection, "[\"say\"]".into())).await.unwrap(),
			OrdinaryStatus::Prepared
		));
		assert_eq!(
			send(a.commit_ordinary(text("say"), "[\"say\"]".into())).await.unwrap(),
			1
		);
		assert!(matches!(
			send(a.inspect_ordinary(text("say"), 0, "[\"say\"]".into()))
				.await
				.unwrap(),
			Inspection::Committed(1)
		));
		assert!(matches!(
			send(a.prepare_ordinary(text("say"), 0, "[\"say\"]".into()))
				.await
				.unwrap(),
			OrdinaryStatus::Committed(1)
		));
		assert!(matches!(
			send(a.prepare_ordinary(text("abandon"), 1, "[\"say\",\"other\"]".into()))
				.await
				.unwrap(),
			OrdinaryStatus::Prepared
		));
		assert_eq!(send(a.resolve(text("abandon"), Outcome::Abandoned)).await.unwrap(), 1);
		assert!(
			send(a.prepare_ordinary(text("abandon"), 1, "[\"say\",\"other\"]".into()))
				.await
				.is_err()
		);
		assert!(a.close().await.is_ok());
		assert!(b.close().await.is_ok());
	});
	assert!(ar.is_ok() && br.is_ok());
	assert_eq!(at.borrow().revisions, [1, 1, 1, 1, 1]);
	assert!(bt.borrow().revisions.is_empty());
	let mut restored = owner(&first.0).await;
	assert!(matches!(restored.load().await.unwrap(), LoadStatus::Ready));
	assert!(matches!(
		restored.inspect_ordinary(text("say"), 0, &"[\"say\"]".into()).unwrap(),
		Inspection::Committed(1)
	));
}
#[tokio::test]
async fn adoption_preserves_multiple_rooms_and_directories_and_retries_exactly() {
	let temp = Temp::new();
	let (handle, worker) = SessionCommands::open(owner(&temp.0).await, crate::client::Deadline)
		.await
		.unwrap();
	let (events, trace) = super::events();
	let mut checkpoint = Checkpoint::empty();
	for (directory, room) in [("one", "first"), ("two", "second")] {
		let locator = format!("ocapn://{directory}.id");
		let args = vec![serde_json::json!({"locator":locator,"nick":"ada","conversation":{
			"kind":"room","id":room,"directory":locator,"name":"general","held":false,"standing":null,"draft":room}})
		.to_string()
		.into()];
		checkpoint = Command::JoinRoom
			.apply(&checkpoint, &args, &CheckpointRoutes, &())
			.unwrap();
	}
	let raw = checkpoint.encode_for(Access::Admin).unwrap();
	assert_eq!(
		checkpoint.adoption_material().unwrap().as_str().unwrap(),
		format!("[\"adoptWorkspace\",{raw}]")
	);
	let (run, ()) = tokio::join!(worker.run(events), async {
		assert_eq!(
			send(handle.prepare_adoption(text("adopt"), 0, checkpoint))
				.await
				.unwrap(),
			1
		);
		assert_eq!(
			send(handle.prepare_adoption(text("adopt"), 0, Checkpoint::decode(&raw, &CheckpointRoutes).unwrap()))
				.await
				.unwrap(),
			1
		);
		assert!(send(handle.prepare_adoption(text("again"), 1, Checkpoint::empty()))
			.await
			.is_err());
		let state = handle
			.view()
			.read(|s| s.checkpoint().unwrap().encode_for(Access::Admin).unwrap())
			.unwrap();
		assert_eq!(state, raw);
		handle.close().await.unwrap();
	});
	run.unwrap();
	assert_eq!(trace.borrow().revisions, [1]);
}
fn link_result() -> DocumentText {
	let link = glowcap::format_sturdyref(
		&glowcap::parse_locator("ocapn://directory.id").unwrap(),
		b"room-link",
		glowcap::CaptpVersion::V1_0,
	)
	.unwrap();
	serde_json::json!({"roomLink":link}).to_string().into()
}
fn plan(handle: &SessionCommands) -> Rc<results::Plan> {
	handle
		.view()
		.read(|s| {
			Rc::new(
				results::Command::EnsureRoomLink
					.prepare(s.checkpoint().unwrap(), &["room".into()], &CheckpointRoutes, false)
					.unwrap(),
			)
		})
		.unwrap()
}
#[tokio::test]
async fn result_queue_publishes_each_boundary_before_reply_and_deduplicates() {
	let temp = Temp::new();
	let (handle, worker) = SessionCommands::open(owner(&temp.0).await, crate::client::Deadline)
		.await
		.unwrap();
	let (events, trace) = super::events();
	let (run, ()) = tokio::join!(worker.run(events), async {
		command(&handle, "join", 0, Command::JoinRoom, join()).await.unwrap();
		let plan = plan(&handle);
		assert!(matches!(
			send(handle.prepare_result(text("link"), 1, "link".into(), plan.clone()))
				.await
				.unwrap(),
			ResultStatus::Prepared
		));
		assert!(send(handle.recover_result(text("link"))).await.is_err());
		assert!(matches!(
			send(handle.prepare_result(text("link"), 1, "link".into(), plan.clone()))
				.await
				.unwrap(),
			ResultStatus::Prepared
		));
		assert_eq!(
			send(handle.commit_result(text("link"), Some("link".into()), Text::new(link_result()).unwrap()))
				.await
				.unwrap(),
			2
		);
		let boundaries = trace.borrow().revisions.clone();
		assert_eq!(boundaries, [1, 1, 1, 1, 2, 2]);
		assert_eq!(
			send(handle.commit_result(text("link"), Some("link".into()), Text::new(link_result()).unwrap()))
				.await
				.unwrap(),
			2
		);
		assert_eq!(send(handle.recover_result(text("link"))).await.unwrap(), 2);
		assert!(matches!(
			send(handle.prepare_result(text("link"), 0, "link".into(), plan))
				.await
				.unwrap(),
			ResultStatus::Committed { revision: 2, .. }
		));
		assert_eq!(trace.borrow().revisions, boundaries);
		assert!(send(handle.commit_result(
			text("link"),
			Some("different".into()),
			Text::new(link_result()).unwrap()
		))
		.await
		.is_err());
		handle.close().await.unwrap();
	});
	run.unwrap();
	let mut restored = owner(&temp.0).await;
	assert!(matches!(restored.load().await.unwrap(), LoadStatus::Ready));
	assert_eq!(restored.state().unwrap().revision().unwrap(), 2);
	assert_eq!(restored.state().unwrap().pending_ids().unwrap().len(), 0);
}
#[tokio::test]
async fn failed_result_application_keeps_its_successful_storage_notification() {
	let temp = Temp::new();
	let (handle, worker) = SessionCommands::open(owner(&temp.0).await, crate::client::Deadline)
		.await
		.unwrap();
	let (events, trace) = super::events();
	let (run, ()) = tokio::join!(worker.run(events), async {
		command(&handle, "join", 0, Command::JoinRoom, join()).await.unwrap();
		let plan = plan(&handle);
		send(handle.prepare_result(text("link"), 1, "link".into(), plan.clone()))
			.await
			.unwrap();
		assert!(
			send(handle.commit_result(text("link"), Some("link".into()), text("invalid returned JSON")))
				.await
				.is_err()
		);
		assert_eq!(trace.borrow().revisions, [1, 1, 1]);
		assert!(matches!(
			send(handle.prepare_result(text("link"), 1, "link".into(), plan))
				.await
				.unwrap(),
			ResultStatus::Returned(_)
		));
		assert!(
			command(&handle, "blocked", 1, Command::SetStanding, vec!["away".into()])
				.await
				.is_err()
		);
		assert!(send(handle.recover_result(text("link"))).await.is_err());
		assert!(send(handle.resolve(text("link"), Outcome::Abandoned)).await.is_err());
		assert_eq!(trace.borrow().revisions, [1, 1, 1]);
		handle.close().await.unwrap();
	});
	run.unwrap();
	// Startup cannot publish a session whose retained result cannot be applied.
	assert!(SessionCommands::open(owner(&temp.0).await, crate::client::Deadline)
		.await
		.is_err());
}
#[tokio::test]
async fn effect_admission_counts_retained_text_capacity_and_releases_unsent_work() {
	let temp = Temp::new();
	let (handle, worker) = SessionCommands::open(owner(&temp.0).await, crate::client::Deadline)
		.await
		.unwrap();
	let mut material = String::with_capacity(MAX_RETAINED_BYTES);
	material.push('x');
	assert!(matches!(
		handle.prepare_ordinary(text("full"), 0, material.into()),
		Err(AdmissionError::Full)
	));
	let mut result = String::with_capacity(MAX_RETAINED_BYTES);
	result.push('x');
	assert!(matches!(
		handle.commit_result(text("full"), None, Text::new(result.into()).unwrap()),
		Err(AdmissionError::Full)
	));
	let admissions: Vec<_> = (0..MAX_PENDING)
		.map(|_| handle.prepare_adoption(text("unsent"), 0, Checkpoint::empty()).unwrap())
		.collect();
	assert!(matches!(
		handle.resolve(text("full"), Outcome::Abandoned),
		Err(AdmissionError::Full)
	));
	drop(admissions);
	let pending = handle
		.prepare_ordinary(text("sent"), 0, "say".into())
		.unwrap()
		.send()
		.unwrap();
	let (events, trace) = super::events();
	let (run, close, reply) = tokio::join!(worker.run(events), handle.close(), pending.wait());
	run.unwrap();
	close.unwrap();
	assert!(matches!(reply.unwrap(), OrdinaryStatus::Prepared));
	assert_eq!(trace.borrow().revisions, [0]);
}

#[tokio::test]
async fn shared_plans_are_charged_per_request_without_copying_their_graph() {
	let temp = Temp::new();
	let (handle, worker) = SessionCommands::open(owner(&temp.0).await, crate::client::Deadline)
		.await
		.unwrap();
	let (events, _) = events();
	let (run, ()) = tokio::join!(worker.run(events), async {
		command(&handle, "join", 0, Command::JoinRoom, join()).await.unwrap();
		command(
			&handle,
			"draft",
			1,
			Command::SetDraft,
			vec!["room".into(), "x".repeat(65536).into()],
		)
		.await
		.unwrap();
		let plan = plan(&handle);
		let mut admissions = Vec::new();
		while let Ok(ticket) = handle.prepare_result(text("held"), 2, "material".into(), plan.clone()) {
			admissions.push(ticket);
		}
		assert!(admissions.len() > 1 && admissions.len() < MAX_PENDING);
		assert!(plan.retained_bytes() >= 65536);
		assert_eq!(Rc::strong_count(&plan), admissions.len() + 1);
		drop(admissions);
		assert_eq!(Rc::strong_count(&plan), 1);
		assert!(handle
			.prepare_result(text("released"), 2, "material".into(), plan)
			.is_ok());
		handle.close().await.unwrap();
	});
	run.unwrap();
}

#[tokio::test]
async fn handed_invitation_acceptance_is_atomic_and_retries_after_handoff_retirement() {
	let temp = Temp::new();
	let (handle, worker) = SessionCommands::open(owner(&temp.0).await, crate::client::Deadline)
		.await
		.unwrap();
	let (events, trace) = super::events();
	let link = glowcap::format_sturdyref(
		&glowcap::parse_locator("ocapn://directory.id").unwrap(),
		b"handed",
		glowcap::CaptpVersion::V1_0,
	)
	.unwrap();
	let invitation: DocumentText =
		serde_json::json!({"kind":"room-link","id":"handed","directory":"ocapn://directory.id",
		"locator":"ocapn://directory.id","nick":"ada","label":"private","from":"grace","link":link})
		.to_string()
		.into();
	let (run, ()) = tokio::join!(worker.run(events), async {
		command(&handle, "join", 0, Command::JoinRoom, join()).await.unwrap();
		assert!(send(handle.prepare_handed_invitation(
			text("collision"),
			1,
			invitation.clone(),
			["handed".into(), "room".into()]
		))
		.await
		.is_err());
		handle
			.view()
			.read(|state| {
				assert_eq!(state.revision().unwrap(), 1);
				let checkpoint: serde_json::Value =
					serde_json::from_str(&state.checkpoint().unwrap().encode_for(Access::Admin).unwrap()).unwrap();
				assert_eq!(checkpoint["invitations"].as_array().unwrap().len(), 0);
				assert_eq!(checkpoint["conversations"].as_array().unwrap().len(), 1);
			})
			.unwrap();
		assert_eq!(
			send(handle.prepare_handed_invitation(text("accept"), 1, invitation, ["handed".into(), "private".into()]))
				.await
				.unwrap(),
			2
		);
		// Admission recognizes the original accept identity before trying to
		// reconstruct a handoff that may no longer be present in the runtime.
		assert_eq!(
			send(handle.prepare_handed_invitation(
				text("accept"),
				1,
				"gone".into(),
				["handed".into(), "private".into()]
			))
			.await
			.unwrap(),
			2
		);
		handle.close().await.unwrap();
	});
	run.unwrap();
	assert_eq!(trace.borrow().revisions, [1, 2]);
	let (handle, worker) = SessionCommands::open(owner(&temp.0).await, crate::client::Deadline)
		.await
		.unwrap();
	let (events, trace) = super::events();
	let (run, ()) = tokio::join!(worker.run(events), async {
		assert_eq!(
			command(
				&handle,
				"accept",
				1,
				Command::AcceptInvitation,
				vec!["handed".into(), "private".into()]
			)
			.await
			.unwrap(),
			2
		);
		handle.close().await.unwrap();
	});
	run.unwrap();
	assert!(trace.borrow().revisions.is_empty());
}
