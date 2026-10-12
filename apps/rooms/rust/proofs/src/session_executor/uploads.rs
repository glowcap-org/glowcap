//! Receipt-owned uploads preserve staging, exact sources and bounded streaming.
use super::*;
use rooms_application::{
	content::permissions::Permission,
	content::session::uploads::{Description, Intent as UploadIntent, Kind, Outcome},
	files::{CHUNK_BYTES, FileDescription},
};
use std::cell::RefCell;
const FILES: Schema = Schema {
	id: 0x5355504c44303031,
	version: 1,
	max_payload: 64,
	// Three durable fixture fields, one live upload and the managed binding.
	max_edges: 5,
};
const SIZE: usize = CHUNK_BYTES * 2 + 17;
const REPLY_BYTES: usize = CHUNK_BYTES + 8192;
#[derive(Default)]
pub(super) struct Trace {
	pub(super) steps: RefCell<Vec<&'static str>>,
	pub(super) writes: RefCell<Vec<usize>>,
	pub(super) deferred: Cell<bool>,
	pub(super) readers: RefCell<Vec<Ref>>,
	short: Cell<bool>,
	malformed: Cell<bool>,
	refused: Cell<Option<&'static str>>,
	refuse_discard: Cell<bool>,
}
struct Target(Rc<Trace>);
impl Content for Target {
	fn requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[], &[])
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<loam::ReferenceRequest>> {
		Ok(if input.verb == "configureLiveUpload" {
			vec![loam::ReferenceRequest::SaveLive(Ref::try_from(&input.args[0]).unwrap())]
		} else if input.verb == "configure" {
			input
				.args
				.iter()
				.map(|value| loam::ReferenceRequest::Save {
					reference: Ref::try_from(value).unwrap(),
					uri: None,
				})
				.collect()
		} else if matches!(
			input.verb,
			"attachRetained" | rooms_application::room::correlation::POST_FILES
		) {
			(0..input.field_count).map(loam::ReferenceRequest::Restore).collect()
		} else {
			Vec::new()
		})
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		if matches!(input.verb, "configure" | "configureLiveUpload") {
			for value in input.args {
				call.append_reference(&Ref::try_from(value).unwrap())?;
			}
			return Ok(Argument::Void);
		}
		match (input.payload, input.verb) {
			(b"files", "attachRetained") => {
				assert_eq!(input.args[0].as_str(), Some("file.bin"));
				self.0.steps.borrow_mut().push("attach");
				if self.0.refused.get() == Some("attach") {
					return Err(loam::refusal("rate-limited: retry-after-ms=1000; scope=upload"));
				}
				if self.0.malformed.get() {
					return Ok(true.into());
				}
				Ok(Argument::List(vec![
					call.disclose(if self.0.deferred.get() { 3 } else { 0 }, false)?,
					call.disclose(1, false)?,
				]))
			}
			(b"files", rooms_application::room::correlation::POST_FILES) => {
				assert_eq!(input.args.len(), 3);
				assert_eq!(&input.args[..2], ["caption".into(), "[]".into()]);
				assert!(rooms_application::room::correlation::valid(
					input.args[2].as_str().unwrap()
				));
				self.0.steps.borrow_mut().push("post");
				if self.0.refused.get() == Some("post") {
					return Err(loam::refusal("rate-limited: retry-after-ms=1000; scope=message"));
				}
				Ok(Argument::List(vec![23.into(), call.disclose(2, false)?]))
			}
			(b"line", "refile") => {
				assert_eq!(input.args, ["caption".into(), 0.into()]);
				self.0.steps.borrow_mut().push("refile");
				Ok(Argument::Void)
			}
			(b"source", "read") => {
				let offset = input.args[0].as_i64().unwrap() as usize;
				let length = input.args[1].as_i64().unwrap() as usize;
				assert_eq!(length, CHUNK_BYTES.min(SIZE - offset));
				assert!(offset < SIZE);
				self.0.steps.borrow_mut().push("read");
				Ok(Argument::Bytes(if self.0.short.get() {
					Vec::new()
				} else {
					vec![7; length.min(SIZE - offset)]
				}))
			}
			(b"upload", "write") => {
				let bytes = input.args[0].as_bytes().unwrap();
				assert!(bytes.len() <= CHUNK_BYTES && bytes.iter().all(|byte| *byte == 7));
				self.0.steps.borrow_mut().push("write");
				self.0.writes.borrow_mut().push(bytes.len());
				Ok(Argument::Void)
			}
			(b"upload", "discard") => {
				self.0.steps.borrow_mut().push("discard");
				if self.0.refuse_discard.get() {
					return Err(loam::refusal("discard was not confirmed"));
				}
				Ok(Argument::Void)
			}
			_ => Err(loam::refusal("unexpected upload target call")),
		}
	}
}
struct PreparedSource(Rc<Trace>);
impl rooms_glowcap::client::sources::Reader for PreparedSource {
	fn read(
		&self,
		offset: usize,
		length: usize,
	) -> std::pin::Pin<Box<dyn std::future::Future<Output = std::result::Result<Vec<u8>, String>>>> {
		let trace = self.0.clone();
		Box::pin(async move {
			assert_eq!(length, CHUNK_BYTES.min(SIZE - offset));
			assert!(offset < SIZE);
			trace.steps.borrow_mut().push("read");
			Ok(vec![7; length])
		})
	}
}
fn registration(trace: Rc<Trace>) -> Registration {
	Registration {
		schema: FILES.id,
		version: 1,
		graph: None,
		methods: [
			"configure",
			"configureLiveUpload",
			"attachRetained",
			rooms_application::room::correlation::POST_FILES,
			"read",
			"write",
			"discard",
			"refile",
		]
		.into_iter()
		.map(|verb| Method {
			verb: verb.into(),
			retry: if matches!(verb, "configure" | "configureLiveUpload") {
				Retry::Idempotent
			} else {
				Retry::ReadOnly
			},
		})
		.collect(),
		content: Box::new(Target(trace)),
	}
}
fn coordinate(role: custody::Role, slot: u64) -> custody::Coordinate {
	custody::Coordinate {
		role,
		key: custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap()),
	}
}
fn workspace() -> Intent {
	Intent::decode(&serde_json::json!({
		"version":1, "directories":[{"id":"directory","access":key::<custody::DirectoryAccess>(),"home":true,"nick":"peer","nickAllocation":"exact","standing":null}],
		"conversations":[{"kind":"room","id":"room","directory":"directory","name":"room","access":null,"files":key::<custody::RoomFiles>(),"lines":[{"id":1,"handle":key::<custody::Line>()}],"control":null,"reconnect":"manual","standing":null,"draft":""}],
		"invitations":[],"active":"room","standing":"","ignored":[],"keepHistory":true,"connection":"relay","archive":null,"archiveControl":null,"operators":[],"peering":[]
	}).to_string()).unwrap()
}
pub(super) async fn request(
	host: &Host,
	source: &Ref,
	blob: &Ref,
	id: &str,
	kind: Kind,
	files: bool,
) -> (Vec<Argument>, String) {
	let base = host.send(source, "snapshot", &[]).await.unwrap().as_list().unwrap()[0]
		.as_i64()
		.unwrap() as u64;
	let description = FileDescription::parse("file.bin", "application/octet-stream", SIZE as u64, 0, 0).unwrap();
	let intent = UploadIntent {
		upload: kind,
		operation: id.into(),
		base,
		conversation: "room".into(),
		caption: "caption".into(),
		previews: "[]".into(),
		keep: List::new(if matches!(kind, Kind::Refile(_)) {
			vec![0]
		} else {
			vec![]
		})
		.unwrap(),
		files: List::new(if files {
			vec![Description::from_file(&description)]
		} else {
			vec![]
		})
		.unwrap(),
	};
	let mut args = vec![id.into(), Argument::Integer(base as i64), "room".into()];
	match kind {
		Kind::Post => args.extend(["caption".into(), "[]".into()]),
		Kind::Refile(line) => args.extend([Argument::Integer(line as i64), "caption".into(), 0.into()]),
	}
	if files {
		args.extend([
			"file".into(),
			"file.bin".into(),
			"application/octet-stream".into(),
			Argument::Integer(SIZE as i64),
			blob.clone().into(),
			0.into(),
			0.into(),
		]);
	}
	(args, intent.canonical().unwrap())
}
pub(super) async fn outcome(host: &Host, source: &Ref, id: &str, canonical: &str) -> Outcome {
	assert_eq!(finished(host, source, id, source).await.as_str(), Some("committed"));
	let value = host
		.send(source, "effect-result", &[id.into(), canonical.into()])
		.await
		.unwrap();
	let data = value
		.as_str()
		.or_else(|| value.as_list().and_then(|rows| rows[0].as_str()))
		.unwrap();
	serde_json::from_str(data).unwrap()
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn uploads_retain_original_batches_sources_and_stream_without_replaying() {
	run().await;
}
pub(super) async fn run() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(15_000, async {
				let database = Database::new("uploads");
				let mut schemas = managed::schemas();
				schemas.push(FILES);
				let mut limits = crate::session_storage::limits_for_input(
					64,
					16,
					loam::ValueBounds {
						values: 64,
						capabilities: 8,
						bytes: 8192,
						..Default::default()
					},
					loam::ValueBounds {
						values: 64,
						capabilities: 8,
						bytes: REPLY_BYTES,
						..Default::default()
					},
				);
				// The forwarding owner has its own reply allowance. Callback
				// demand and the executor's private reply do not enlarge it.
				limits.forward_reply_bytes = REPLY_BYTES;
				limits.pending_bytes = limits.call_bytes * limits.max_operations;
				limits.ingress_bytes = limits.pending_bytes;
				limits.max_leases *= limits.max_operations;
				let mut store = database.open(true, &schemas, limits).await;
				let policy = rooms_glowcap::policy::descriptor().unwrap();
				let resource = environment::create(
					&store,
					&policy,
					schemas[0],
					&managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay)
						.unwrap(),
					4,
				)
				.await;
				let mut resources = Vec::new();
				for payload in [b"files".as_slice(), b"upload", b"source", b"line", b"source"] {
					resources.push(environment::create(&store, &policy, FILES, payload, 1).await);
				}
				let host = Host::from_seed([128; 32]).unwrap();
				host.set_ingress_limits(4096, 1024 * 1024, (CHUNK_BYTES * 2) as u32)
					.unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(REPLY_BYTES).unwrap(),
				);
				// This streaming fixture exercises custody and interruption beyond
				// ordinary bursts; admission's default profile has its own proofs.
				owner
					.configure_admission(
						rooms_application::admission::Settings::parse(
							|key| (key == "admission-rates").then(|| "message=64/64,upload=64/64".into()),
							4096,
							8,
						)
						.unwrap(),
					)
					.unwrap();
				let trace = Rc::new(Trace::default());
				let mut attachment = store
					.attach(&host, vec![owner.registration(), registration(trace.clone())])
					.unwrap();
				attachment.start_live(None, 128).unwrap();
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				owner
					.activity()
					.bind_incarnation(attachment.live_incarnation().unwrap().unwrap())
					.unwrap();
				let mut targets = Vec::new();
				for resource in &resources {
					targets.push(environment::restore(&attachment, *resource).await.0);
				}
				host.send(
					&targets[0],
					"configure",
					&[
						targets[1].clone().into(),
						targets[2].clone().into(),
						targets[3].clone().into(),
					],
				)
				.await
				.unwrap();
				for (role, target) in [
					(custody::Role::DirectoryAccess, &targets[0]),
					(custody::Role::RoomFiles, &targets[0]),
					(custody::Role::Line, &targets[3]),
				] {
					owner.import(coordinate(role, 1), target.clone(), None).await.unwrap();
				}
				owner.replace_workspace(&workspace()).await.unwrap();
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
				let (source, _) = owner.derive(terms, 1, ControlPowers::default()).await.unwrap();
				let (args, canonical) = request(&host, &source, &targets[2], "posted-upload", Kind::Post, true).await;
				let pool = rooms_glowcap::client::sources::Sources::new(Platform::default());
				let original = UploadIntent::read(&canonical).unwrap();
				let file = rooms_glowcap::client::sources::Source::reader(
					original.files.as_slice()[0].file().unwrap(),
					PreparedSource(trace.clone()),
				);
				let client = rooms_glowcap::client::workspace::Workspace::local(
					host.clone(),
					Platform::default(),
					source.clone(),
				);
				let prepared = client.prepare_upload(&original, &pool, vec![file]).await.unwrap();
				platform.suspended.set(true);
				assert_eq!(
					prepared.submit().await.unwrap(),
					rooms_glowcap::client::workspace::EffectStatus::Pending
				);
				platform.tasks.borrow().last().unwrap().abort();
				for _ in 0..3 {
					environment::yield_turn().await;
				}
				assert!(trace.steps.borrow().is_empty(), "unpolled pipeline cannot dispatch");
				let mut replaced = args.clone();
				replaced[9] = targets[4].clone().into();
				assert!(
					mutate(&host, &source, "sendFiles", &replaced).await.is_err(),
					"equal file descriptions cannot replace original source authority"
				);
				platform.suspended.set(false);
				owner.resume_pending().unwrap();
				let applied = outcome(&host, &source, "posted-upload", &canonical).await;
				assert_eq!(
					applied.id.unwrap().get(),
					23,
					"upload preserves the room's posted line identity"
				);
				assert!(
					applied.files_complete && applied.line.is_some(),
					"failure={:?}, steps={:?}",
					applied.failure,
					trace.steps.borrow()
				);
				assert_eq!(
					*trace.steps.borrow(),
					["attach", "post", "read", "write", "read", "write", "read", "write"]
				);
				assert_eq!(*trace.writes.borrow(), [CHUNK_BYTES, CHUNK_BYTES, 17]);
				let before = trace.steps.borrow().len();
				assert_eq!(
					prepared.submit().await.unwrap(),
					rooms_glowcap::client::workspace::EffectStatus::Committed
				);
				assert_eq!(trace.steps.borrow().len(), before);
				// Admission transfers source lifetime to the exact hosted actors.
				// Releasing the request observer cannot expire the receiver's roots.
				let (_, abandoned) = request(&host, &source, &targets[2], "released-upload", Kind::Post, true).await;
				let original = UploadIntent::read(&abandoned).unwrap();
				let file = rooms_glowcap::client::sources::Source::reader(
					original.files.as_slice()[0].file().unwrap(),
					PreparedSource(trace.clone()),
				);
				let abandoned_request = client.prepare_upload(&original, &pool, vec![file]).await.unwrap();
				platform.suspended.set(true);
				assert_eq!(
					abandoned_request.submit().await.unwrap(),
					rooms_glowcap::client::workspace::EffectStatus::Pending
				);
				platform.tasks.borrow().last().unwrap().abort();
				for _ in 0..3 {
					environment::yield_turn().await;
				}
				drop(abandoned_request);
				for _ in 0..3 {
					environment::yield_turn().await;
				}
				platform.suspended.set(false);
				owner.resume_pending().unwrap();
				assert!(
					outcome(&host, &source, "released-upload", &abandoned)
						.await
						.files_complete
				);
				super::upload_interruption::run(&host, &owner, &platform, &targets[0], &source, &targets[2], &trace)
					.await;
				let before = trace.steps.borrow().len();
				trace.short.set(true);
				let (args, canonical) =
					request(&host, &source, &targets[2], "incomplete-upload", Kind::Post, true).await;
				mutate(&host, &source, "sendFiles", &args).await.unwrap();
				let applied = outcome(&host, &source, "incomplete-upload", &canonical).await;
				assert_eq!(
					applied.id.unwrap().get(),
					23,
					"partial file fill retains the committed line identity"
				);
				assert!(
					!applied.files_complete && applied.line.is_some(),
					"failed fill preserves the applied primary result"
				);
				assert_eq!(&trace.steps.borrow()[before..], ["attach", "post", "read", "discard"]);
				trace.short.set(false);
				let (args, canonical) = request(
					&host,
					&source,
					&targets[2],
					"refile-without-new-files",
					Kind::Refile(1),
					false,
				)
				.await;
				mutate(&host, &source, "refileLine", &args).await.unwrap();
				assert!(
					outcome(&host, &source, "refile-without-new-files", &canonical)
						.await
						.files_complete
				);
				assert_eq!(trace.steps.borrow().last(), Some(&"refile"));
				for (stage, failed_cleanup) in [("attach", false), ("post", false), ("post", true)] {
					trace.refused.set(Some(stage));
					trace.refuse_discard.set(failed_cleanup);
					let before = trace.steps.borrow().len();
					let id = format!("refused-{stage}-{failed_cleanup}");
					let (args, canonical) = request(&host, &source, &targets[2], &id, Kind::Post, true).await;
					mutate(&host, &source, "sendFiles", &args).await.unwrap();
					let status = if failed_cleanup { "unknown" } else { "unsent" };
					assert_eq!(finished(&host, &source, &id, &source).await.as_str(), Some(status));
					let value = host
						.send(
							&source,
							"effect-result",
							&[id.as_str().into(), canonical.as_str().into()],
						)
						.await
						.unwrap();
					let rows = value.as_list().unwrap();
					assert_eq!(
						rows[0].as_str(),
						Some(if failed_cleanup { "unknown" } else { "refused" })
					);
					assert!(rows[1].as_str().unwrap().contains("rate-limited:"));
					{
						let steps = trace.steps.borrow();
						assert_eq!(
							&steps[before..],
							if stage == "attach" {
								&["attach"][..]
							} else {
								&["attach", "post", "discard"][..]
							}
						);
					}
					mutate(&host, &source, "sendFiles", &args).await.unwrap();
					assert_eq!(
						trace.steps.borrow().len(),
						before + if stage == "attach" { 1 } else { 3 },
						"refusal replay ran external work"
					);
				}
				trace.refused.set(None);
				trace.refuse_discard.set(false);
				trace.malformed.set(true);
				let (args, _) = request(&host, &source, &targets[2], "unknown-upload", Kind::Post, true).await;
				mutate(&host, &source, "sendFiles", &args).await.unwrap();
				assert_eq!(
					finished(&host, &source, "unknown-upload", &source).await.as_str(),
					Some("unknown")
				);
				owner
					.import(coordinate(custody::Role::RoomFiles, 2), targets[0].clone(), None)
					.await
					.unwrap();
				let mut alias = workspace();
				let session::workspace::Conversation::Room(room) = &mut alias.conversations.as_mut_slice()[0] else {
					panic!("room")
				};
				room.files = Some(custody::FieldKey::new(
					NonZeroU64::new(2).unwrap(),
					NonZeroU64::new(1).unwrap(),
				));
				owner.replace_workspace(&alias).await.unwrap();
				let (args, _) = request(&host, &source, &targets[2], "alias-upload", Kind::Post, true).await;
				assert!(
					mutate(&host, &source, "sendFiles", &args).await.is_err(),
					"unresolved batches exclude actual files authority through an alias"
				);
				super::direct_files::run(&host, &owner, &targets[3], &targets[2], &trace).await;
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop((owner, attachment));
				environment::close(&mut store).await;
				database.remove();
			})
			.await
			.expect("composite upload journey deadline");
		})
		.await;
}
