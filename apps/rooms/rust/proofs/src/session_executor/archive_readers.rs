//! Recursive archive/blob facades share actual session and upstream admission.
use super::*;
use rooms_application::content::permissions::Permission;

struct ArchiveTarget(Rc<Cell<usize>>);
impl Content for ArchiveTarget {
	fn requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[], &[])
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<loam::ReferenceRequest>> {
		if input.verb == "configure" {
			Ok(vec![loam::ReferenceRequest::Save {
				reference: Ref::try_from(&input.args[0]).unwrap(),
				uri: None,
			}])
		} else if matches!(input.verb, "blob" | "attachment" | "narrow") {
			Ok(vec![loam::ReferenceRequest::Restore(0)])
		} else {
			Ok(Vec::new())
		}
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		if input.verb == "configure" {
			call.append_reference(&Ref::try_from(&input.args[0]).unwrap())?;
			return Ok(Argument::Void);
		}
		self.0.set(self.0.get() + 1);
		match input.verb {
			"blob" | "attachment" | "narrow" => call.disclose(0, false),
			"read" => Ok(Argument::Bytes(
				if input.payload == b"replacement" {
					b"other"
				} else {
					b"chunk"
				}
				.to_vec(),
			)),
			_ => Ok(Argument::Void),
		}
	}
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn retained_archive_readers_preserve_identity_and_session_file_admission() {
	run().await;
}
pub(super) async fn run() {
	tokio::task::LocalSet::new().run_until(async {
		environment::within(10_000, async {
			let database = Database::new("archive-readers");
			let mut schemas = managed::schemas();
			let schema = Schema { max_edges: 2, ..TARGET };
			schemas.push(schema);
				let mut limits = managed::reader_limits(crate::session_storage::limits_for(24, 8, loam::ValueBounds {
					values: 32, capabilities: 4, bytes: 8192, ..Default::default()
				})).unwrap();
			limits.max_leases *= limits.max_operations;
			// The retained source call and its managed upstream share one Store.
			// Each needs an independently admitted whole-call reservation.
			limits.pending_bytes = limits.call_bytes.checked_mul(2).unwrap();
			limits.ingress_bytes = limits.pending_bytes;
			let coordinate = custody::Coordinate { role: custody::Role::ArchiveAccess, key: key() };
			let coordinate_text = serde_json::to_string(&coordinate).unwrap();
			limits.continuation_bytes = loam::ReadScopeBounds {
				interfaces: 2, methods: 5, verb_bytes: 28, result_roles: 3,
				targets: limits.max_continuation_targets,
			}.size_bound(loam::ValueBounds {
				values: 2, capabilities: 1, bytes: coordinate_text.len(), ..Default::default()
			}, "archive-reader".len()).unwrap();
			let mut store = database.open(true, &schemas, limits).await;
			let policy = rooms_glowcap::policy::descriptor().unwrap();
			let resource = environment::create(&store, &policy, schemas[0], &managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay).unwrap(), 3).await;
			let archive = environment::create(&store, &policy, schema, b"archive", 1).await;
			let replacement = environment::create(&store, &policy, schema, b"replacement", 1).await;
			let host = Host::from_seed([120; 32]).unwrap();
			let owner = managed::Session::new(host.clone(), Platform::default(), std::num::NonZeroUsize::new(8192).unwrap());
			let calls = Rc::new(Cell::new(0));
			let target = Registration {
				schema: schema.id, version: 1, graph: None,
				methods: ["configure", "read", "narrow", "attachment", "blob", "write", "history"].into_iter().map(|verb| Method {
					verb: verb.into(), retry: if verb == "configure" { Retry::Idempotent } else { Retry::ReadOnly },
				}).collect(),
				content: Box::new(ArchiveTarget(calls.clone())),
			};
			let mut attachment = store.attach(&host, vec![owner.registration(), target]).unwrap();
			environment::start_live(&attachment, None, 32).await;
			let (root, root_control) = environment::restore(&attachment, resource).await;
			owner.bind(root.clone(), root_control.clone()).unwrap();
			owner.initialize().await.unwrap();
			let (archive, archive_control) = environment::restore(&attachment, archive).await;
			host.send(&archive, "configure", &[Argument::Reference(archive.clone())]).await.unwrap();
			owner.import(coordinate, archive.clone(), None).await.unwrap();
			let (replacement, _) = environment::restore(&attachment, replacement).await;
			host.send(&replacement, "configure", &[replacement.clone().into()]).await.unwrap();
			let replacement_coordinate = custody::Coordinate {
				role: custody::Role::ArchiveAccess,
				key: custody::FieldKey::new(NonZeroU64::new(2).unwrap(), NonZeroU64::new(1).unwrap()),
			};
			owner.import(replacement_coordinate, replacement.clone(), None).await.unwrap();
			let seat = custody::Coordinate { role: custody::Role::RoomSeat, key: key() };
			let bridge_calls = Rc::new(Cell::new(0));
			let bridge_dispatches = bridge_calls.clone();
			let history_target = host.spawn(move |verb, _| {
				let verb = verb.ok_or("fixture requires a method")?;
				if verb == rooms_application::bridge::ASK {
					bridge_dispatches.set(bridge_dispatches.get() + 1);
					return Ok(Argument::String(r#"{"scope":"network","title":"Identity","said":"","fields":[],"actions":[{"id":"connect","label":"Connect","busyLabel":"Connecting","tone":"primary","remembered":true}]}"#.into()));
				}
				use rooms_application::room::{history, line};
				Ok(Argument::List((0..history::MAX_LINES).map(|_| {
					Argument::List(vec!["sender".into(), "x".repeat(line::MAX_LINE_BYTES).into(), 1.into(), "[]".into()])
				}).collect()))
			}).unwrap();
			owner.import(seat, history_target.clone(), None).await.unwrap();
			let terms = policy.value_for_kind(session::KIND, &[Permission::History.key(), Permission::ReadArchive.key(), Permission::ReadFile.key()], &[]).unwrap();
			let powers = ControlPowers {policy_ceiling: Some(terms), pause: true, resume: true, revoke: true, ..Default::default() };
			let (source, control) = owner.derive(terms, 1, powers).await.unwrap();
			assert!(host.send(&source, "workspace-history-reader", &["selected".into(), false.into()]).await.is_err(), "an unconfigured device archive cannot substitute for saved authority");
			let mut selected = Intent::empty();
			selected.archive = Some(custody::FieldKey::new(coordinate.key.slot(), coordinate.key.generation()));
			owner.replace_workspace(&selected).await.unwrap();
			let selected_reader = Ref::try_from(&host.send(&source, "workspace-history-reader", &["selected".into(), false.into()]).await.unwrap()).unwrap();
			selected.archive = Some(custody::FieldKey::new(replacement_coordinate.key.slot(), replacement_coordinate.key.generation()));
			owner.replace_workspace(&selected).await.unwrap();
			let changed_reader = Ref::try_from(&host.send(&source, "workspace-history-reader", &["selected".into(), false.into()]).await.unwrap()).unwrap();
			assert!(matches!(host.send(&selected_reader, "read", &[0.into(), 5.into()]).await.unwrap(), Argument::Bytes(bytes) if bytes == b"chunk"), "selection changes cannot redirect a held reader");
			assert!(matches!(host.send(&changed_reader, "read", &[0.into(), 5.into()]).await.unwrap(), Argument::Bytes(bytes) if bytes == b"other"), "new readers use the exact selected archive");
			assert!(host.send(&selected_reader, "blob", &["digest".into()]).await.is_err(), "text-only selection grants no files");
			drop((selected_reader, changed_reader, replacement));
			let request: [Argument; 2] = [coordinate_text.into(), true.into()];
			let file_reader = Ref::try_from(&host.send(&source, "file-reader", &[archive.clone().into()]).await.unwrap()).unwrap();
			assert!(matches!(host.send(&file_reader, "read", &[0.into(), 5.into()]).await.unwrap(), Argument::Bytes(bytes) if bytes == b"chunk"));
			let before = calls.get();
			assert!(host.send(&file_reader, "write", &[Argument::Bytes(vec![1])]).await.is_err());
			assert_eq!(calls.get(), before);
			assert!(host.send(&source, "history-reader", &[request[0].clone()]).await.is_err(), "an archive or entrance cannot substitute for an exact seat");
            let reader = Ref::try_from(&host.send(&source, "archive-reader", &request).await.unwrap()).unwrap();
			assert_ne!(reader, archive);
            let narrow = Ref::try_from(&host.send(&reader, "narrow", &[]).await.unwrap()).unwrap();
			assert_eq!(reader, narrow, "same exact target and interface reuse one facade");
            let blob = Ref::try_from(&host.send(&reader, "blob", &["digest".into()]).await.unwrap()).unwrap();
            let again = Ref::try_from(&host.send(&reader, "attachment", &[]).await.unwrap()).unwrap();
			assert_eq!(blob, again);
			assert_ne!(blob, reader, "a blob cannot acquire archive methods");
			let before = calls.get();
			assert!(host.send(&blob, "blob", &["digest".into()]).await.is_err());
			assert!(host.send(&blob, "write", &[Argument::Bytes(vec![1])]).await.is_err());
			assert_eq!(calls.get(), before);
			drop((reader, narrow, again));
			assert!(matches!(host.send(&blob, "read", &[0.into(), 5.into()]).await.unwrap(), Argument::Bytes(bytes) if bytes == b"chunk"));
			host.send(&control, "pause", &[Argument::Bytes(glowcap::loam::control_revision(&host, &control).await.unwrap().to_be_bytes().to_vec())]).await.unwrap();
			let before = calls.get();
			assert!(host.send(&blob, "read", &[0.into(), 5.into()]).await.is_err());
			assert_eq!(calls.get(), before);
			host.send(&control, "resume", &[Argument::Bytes(glowcap::loam::control_revision(&host, &control).await.unwrap().to_be_bytes().to_vec())]).await.unwrap();
			host.send(&archive_control, "pause", &[Argument::Bytes(glowcap::loam::control_revision(&host, &archive_control).await.unwrap().to_be_bytes().to_vec())]).await.unwrap();
			assert!(host.send(&blob, "read", &[0.into(), 5.into()]).await.is_err());
			assert_eq!(calls.get(), before);
			host.send(&archive_control, "resume", &[Argument::Bytes(glowcap::loam::control_revision(&host, &archive_control).await.unwrap().to_be_bytes().to_vec())]).await.unwrap();
			let history = policy.value_for_kind(session::KIND, &[Permission::History.key()], &[]).unwrap();
			let (history_only, _) = owner.derive(history, 1, ControlPowers::default()).await.unwrap();
			let archive_terms = policy.value_for_kind(session::KIND, &[Permission::ReadArchive.key()], &[]).unwrap();
			let (archive_only, reader_control) = owner.derive(archive_terms, 1, ControlPowers { pause: true, resume: true, revoke: true, ..Default::default() }).await.unwrap();
			let archive_workspace = rooms_glowcap::client::workspace::Workspace::local(host.clone(), Platform::default(), archive_only.clone());
			assert!(archive_workspace.snapshot().await.is_err(), "archive reading grants no workspace observation");
			assert!(archive_workspace.device_history(false).await.is_err(), "archive reading grants no device history");
			assert!(archive_workspace.selected_archive(false).await.is_ok(), "ReadArchive independently admits the selected peer");
			assert!(archive_workspace.selected_archive(true).await.is_err(), "selected peer files independently require ReadFile");
			let history_workspace = rooms_glowcap::client::workspace::Workspace::local(host.clone(), Platform::default(), history_only.clone());
			assert!(history_workspace.selected_archive(false).await.is_err(), "History cannot read the selected peer");
			assert!(archive_workspace.history_reader(seat).await.is_err(), "archive reading grants no seat history");
			let observe = policy.value_for_kind(session::KIND, &[Permission::ObserveWorkspace.key()], &[]).unwrap();
			let (observer, observer_control) = owner.derive(observe, 1, ControlPowers { policy_ceiling: Some(observe), pause: true, resume: true, revoke: true, ..Default::default() }).await.unwrap();
			let workspace = rooms_glowcap::client::workspace::Workspace::local(host.clone(), Platform::default(), observer.clone());
			let form = workspace.bridge_form(seat).await.unwrap().unwrap();
			assert_eq!(form.scope.text().as_str(), Some("network"));
			let bridge_reader = workspace.bridge_form_reader(seat).await.unwrap();
			assert!(host.send(&bridge_reader, rooms_application::bridge::SUBMIT, &["connect".into(), "{}".into()]).await.is_err());
			assert!(host.send(&history_only, "bridge-form-reader", &[serde_json::to_string(&seat).unwrap().into()]).await.is_err(), "history does not grant workspace observation");
			assert!(workspace.bridge_form(coordinate).await.is_err(), "an archive cannot stand in for a bridge seat");
			let bridge_before = bridge_calls.get();
			publication_results::lifecycle(&host, &observer_control, "pause").await;
			assert!(host.send(&bridge_reader, rooms_application::bridge::ASK, &[]).await.is_err());
			assert_eq!(bridge_calls.get(), bridge_before);
			publication_results::lifecycle(&host, &observer_control, "resume").await;
			assert!(host.send(&bridge_reader, rooms_application::bridge::ASK, &[]).await.is_ok());
			publication_results::lifecycle(&host, &observer_control, "revoke").await;
			assert!(host.send(&bridge_reader, rooms_application::bridge::ASK, &[]).await.is_err());
			drop((bridge_reader, workspace, observer, observer_control));
			assert!(host.send(&history_only, "file-reader", &[archive.clone().into()]).await.is_err());
			let history_reader = Ref::try_from(&host.send(&history_only, "history-reader", &[serde_json::to_string(&seat).unwrap().into()]).await.unwrap()).unwrap();
			let history_reply = host.send(&history_reader, "history", &[]).await.unwrap();
			let rows = history_reply.as_list().unwrap();
			assert_eq!(rows.len(), rooms_application::room::history::MAX_LINES);
			assert_eq!(rows[99].as_list().unwrap()[1].as_str().unwrap().len(), rooms_application::room::line::MAX_LINE_BYTES);
			drop(history_reply);
			let before = calls.get();
			assert!(host.send(&history_reader, "read", &[0.into(), 5.into()]).await.is_err());
			assert!(host.send(&history_reader, "post", &["forbidden".into()]).await.is_err());
			assert_eq!(calls.get(), before);
			assert!(host.send(&history_only, "archive-reader", &request).await.is_err());
			let text_request = [request[0].clone(), false.into()];
			assert!(host.send(&history_only, "archive-reader", &text_request).await.is_err(), "history is not saved archive access");
			assert!(host.send(&archive_only, "archive-reader", &request).await.is_err(), "archive reading grants no files");
			let text_reader = archive_workspace.archive_reader(coordinate, false).await.unwrap();
			assert!(host.send(&text_reader, "blob", &["digest".into()]).await.is_err());
			host.send(&control, "mutate", &history.set_policy_arguments(1, glowcap::loam::control_revision(&host, &control).await.unwrap())).await.unwrap();
			assert!(host.send(&file_reader, "read", &[0.into(), 5.into()]).await.is_err());
			assert!(host.send(&blob, "read", &[0.into(), 5.into()]).await.is_err());
			host.send(&control, "revoke", &[Argument::Bytes(glowcap::loam::control_revision(&host, &control).await.unwrap().to_be_bytes().to_vec())]).await.unwrap();
			assert!(host.send(&blob, "read", &[0.into(), 5.into()]).await.is_err());
			assert!(host.send(&text_reader, "read", &[]).await.is_ok());
			publication_results::lifecycle(&host, &reader_control, "pause").await;
			assert!(host.send(&text_reader, "read", &[]).await.is_err());
			publication_results::lifecycle(&host, &reader_control, "resume").await;
			assert!(host.send(&text_reader, "read", &[]).await.is_ok());
			publication_results::lifecycle(&host, &reader_control, "revoke").await;
			assert!(host.send(&text_reader, "read", &[]).await.is_err());
			owner.close().await.unwrap();
			let before = calls.get();
			assert!(host.send(&history_reader, "history", &[]).await.is_err());
			assert!(host.send(&file_reader, "read", &[0.into(), 5.into()]).await.is_err());
			assert!(host.send(&text_reader, "read", &[]).await.is_err());
			assert_eq!(calls.get(), before, "a closed session cannot dispatch retained readers");
			drop((file_reader, history_reader, history_target, blob, text_reader, archive_workspace, archive_only, reader_control, history_only, source, control, archive, archive_control, root));
			attachment.close().await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			drop(owner);
			environment::close(&mut store).await;
			database.remove();
		}).await.expect("archive reader proof deadline");
	}).await;
}
