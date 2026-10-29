//! Exact bridge origin, declaration and credential custody through real Loam.
use super::publication_results::{coordinate, lifecycle};
use super::*;
use rooms_application::{
	bridge::{Answers, Form},
	content::session::{bridge, workspace},
	fields::{SafeInteger, Text},
};
use rooms_glowcap::client::workspace::{EffectStatus, Workspace};
use std::cell::RefCell;
#[cfg(target_arch = "wasm32")]
mod indexeddb;
#[cfg(all(test, not(target_arch = "wasm32")))]
mod restart;

#[cfg(target_arch = "wasm32")]
pub(super) async fn physical_recovery() {
	indexeddb::run().await;
}

#[derive(Default)]
struct Stored {
	bytes: RefCell<Option<Vec<u8>>>,
	writes: Cell<usize>,
	staging_writes: Cell<usize>,
	held: environment::Suspension,
}
struct Document(Rc<Stored>, bool);
impl rooms_runtime::documents::Document for Document {
	type Error = std::io::Error;
	fn document(&self) -> rooms_application::documents::SessionDocument {
		rooms_application::documents::SessionDocument::BridgeSecrets
	}
	fn has_pending(&self) -> bool {
		self.1
	}
	async fn read(&mut self) -> std::io::Result<Option<Vec<u8>>> {
		if self.1 {
			return Err(std::io::Error::other("credential observation is pending"));
		}
		Ok(self.0.bytes.borrow().clone())
	}
	async fn replace(
		&mut self,
		bytes: Vec<u8>,
	) -> std::result::Result<(), rooms_application::documents::WriteFailure<Self::Error>> {
		if self.1 {
			return Err(rooms_application::documents::WriteFailure::Unchanged(
				std::io::Error::other("credential observation is pending"),
			));
		}
		self.1 = true;
		let encoded: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
		if !encoded["pending"].as_array().unwrap().is_empty() {
			self.0.staging_writes.set(self.0.staging_writes.get() + 1);
		}
		*self.0.bytes.borrow_mut() = Some(bytes);
		self.0.writes.set(self.0.writes.get() + 1);
		match self.finish_pending().await.unwrap() {
			rooms_runtime::documents::Completion::Write(result) => result,
			_ => unreachable!("owned write"),
		}
	}
	async fn finish_pending(&mut self) -> Option<rooms_runtime::documents::Completion<Self::Error>> {
		if !self.1 {
			return None;
		}
		self.0.held.wait().await;
		self.1 = false;
		Some(rooms_runtime::documents::Completion::Write(Ok(())))
	}
}

const BRIDGE: Schema = Schema {
	id: 0x5342524944474531,
	version: 1,
	max_payload: 64,
	max_edges: 1,
};
struct Bridge {
	form: Rc<RefCell<Form>>,
	calls: Rc<Cell<usize>>,
	unknown: Rc<Cell<bool>>,
}
impl Content for Bridge {
	fn requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[], &[])
	}
	fn invoke(&self, _: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		match input.verb {
			rooms_application::bridge::ASK => Ok(self.form.borrow().encode().unwrap().into()),
			rooms_application::bridge::SUBMIT => {
				assert_eq!(input.payload, b"seat", "dispatch must use the exact selected seat");
				let [action, answers] = input.args else {
					panic!("bridge arguments")
				};
				assert_eq!(action.as_str(), Some("apply"));
				let answers = Answers::decode(answers.as_str().unwrap()).unwrap();
				assert_eq!(answers.get("name").unwrap().as_str(), Some("sender"));
				assert_eq!(answers.get("password").unwrap().as_str(), Some("private credential"));
				self.calls.set(self.calls.get() + 1);
				Ok(if self.unknown.get() {
					true.into()
				} else {
					Argument::Void
				})
			}
			_ => Err(loam::refusal("unsupported bridge fixture method")),
		}
	}
}
fn form() -> Form {
	Form::decode(
		&serde_json::json!({
			"scope":"original-form", "title":"Identity", "said":"",
			"fields":[{"kind":"text","id":"name","label":"Name","required":false},
				{"kind":"secret","id":"password","label":"Password","required":false}],
			"actions":[{"id":"apply","label":"Apply","busyLabel":"Applying","tone":"primary","remembered":true}]
		})
		.to_string(),
	)
	.unwrap()
}
fn seat_key(slot: u64) -> custody::FieldKey<custody::RoomSeat> {
	custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap())
}
async fn terminal(command: &rooms_glowcap::client::workspace::Command<Platform>) -> EffectStatus {
	loop {
		let status = command.status().await.unwrap();
		if status != EffectStatus::Pending {
			return status;
		}
		environment::yield_turn().await;
	}
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn bridge_dispatch_retains_exact_origin_and_never_retries_unknown_first_submission() {
	run().await;
}
pub(super) async fn run() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(15_000, async {
				let database = Database::new("bridge-executor");
				let mut schemas = managed::schemas();
				schemas.push(BRIDGE);
				let limits = managed::production_limits().unwrap();
				let mut store = database.open(true, &schemas, limits).await;
				let policy = rooms_glowcap::policy::descriptor().unwrap();
				let resource = environment::create(
					&store,
					&policy,
					schemas[0],
					&managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay)
						.unwrap(),
					3,
				)
				.await;
				let access = environment::create(&store, &policy, BRIDGE, b"access", 2).await;
				let seat = environment::create(&store, &policy, BRIDGE, b"seat", 2).await;
				let successor = environment::create(&store, &policy, BRIDGE, b"successor", 2).await;
				let host = Host::from_seed([161; 32]).unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(limits.forward_reply_bytes).unwrap(),
				);
				let calls = Rc::new(Cell::new(0));
				let unknown = Rc::new(Cell::new(false));
				let current_form = Rc::new(RefCell::new(form()));
				let registration = Registration {
					schema: BRIDGE.id,
					version: 1,
					graph: None,
					methods: [rooms_application::bridge::ASK, rooms_application::bridge::SUBMIT]
						.into_iter()
						.map(|verb| Method {
							verb: verb.into(),
							retry: Retry::Idempotent,
						})
						.collect(),
					content: Box::new(Bridge {
						form: current_form.clone(),
						calls: calls.clone(),
						unknown: unknown.clone(),
					}),
				};
				let mut attachment = store.attach(&host, vec![owner.registration(), registration]).unwrap();
				environment::start_live(&attachment, None, 128).await;
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control).unwrap();
				owner.initialize().await.unwrap();
				let storage = Rc::new(Stored::default());
				owner
					.configure_credentials(Document(storage.clone(), false))
					.await
					.unwrap();
				let (access, _) = environment::restore(&attachment, access).await;
				let (seat, _) = environment::restore(&attachment, seat).await;
				let (successor, _) = environment::restore(&attachment, successor).await;
				for (role, slot, target) in [
					(custody::Role::DirectoryAccess, 1, &access),
					(custody::Role::RoomAccess, 1, &access),
					(custody::Role::RoomSeat, 1, &seat),
					(custody::Role::RoomAccess, 2, &successor),
					(custody::Role::RoomSeat, 2, &seat),
					(custody::Role::AcceptedAccess, 1, &access),
				] {
					owner
						.import(coordinate(role, slot), target.clone(), None)
						.await
						.unwrap();
				}
				let mut intent = Case::kick().workspace(1);
				let workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
					panic!("room")
				};
				room.moderator = None;
				room.id = Text::new("room".into()).unwrap();
				room.access = Some(custody::FieldKey::new(
					NonZeroU64::new(1).unwrap(),
					NonZeroU64::new(1).unwrap(),
				));
				room.seat = Some(seat_key(1));
				owner.replace_workspace(&intent).await.unwrap();
				let terms = policy
					.value_for_kind(
						session::KIND,
						&session::SUPPORTED.iter().map(|p| p.key()).collect::<Vec<_>>(),
						&[],
					)
					.unwrap();
				let (source, control) = owner
					.derive(
						terms,
						1,
						ControlPowers {
							pause: true,
							resume: true,
							revoke: true,
							..Default::default()
						},
					)
					.await
					.unwrap();
				let (other, _) = owner.derive(terms, 1, ControlPowers::default()).await.unwrap();
				let workspace = Workspace::local(host.clone(), platform.clone(), source.clone());
				let mut request = bridge::Request {
					bridge: bridge::Intent {
						declaration: form(),
						action: rooms_application::bridge::Id::new("apply".into()).unwrap(),
						answers: Answers::decode("{\"name\":\"sender\"}").unwrap(),
					},
					operation: Text::new("bridge-original".into()).unwrap(),
					base: SafeInteger::new(workspace.snapshot().await.unwrap().revision).unwrap(),
					room: Text::new("room".into()).unwrap(),
					seat: seat_key(1),
					access: Some(coordinate(custody::Role::RoomAccess, 1)),
					credentials: Some(serde_json::from_str("\"0123456789abcdef0123456789abcdef\"").unwrap()),
					reapply: None,
				};
				let secrets = Answers::decode("{\"password\":\"private credential\"}").unwrap();
				let command = workspace.prepare_bridge(&request, &secrets).unwrap();
				assert!(!request.canonical().unwrap().contains("private credential"));
				assert_eq!(command.submit().await.unwrap(), EffectStatus::Pending);
				assert_eq!(terminal(&command).await, EffectStatus::Committed);
				assert_eq!(calls.get(), 1);
				assert_eq!(command.submit().await.unwrap(), EffectStatus::Committed);
				assert_eq!(calls.get(), 1, "receipt replay cannot resubmit");
				loop {
					let encoded: serde_json::Value =
						serde_json::from_slice(storage.bytes.borrow().as_ref().unwrap()).unwrap();
					if encoded["pending"].as_array().unwrap().is_empty() {
						break;
					}
					environment::yield_turn().await;
				}
				storage.held.set(true);
				request.operation = Text::new("interrupted-storage".into()).unwrap();
				request.base = SafeInteger::new(workspace.snapshot().await.unwrap().revision).unwrap();
				let interrupted = workspace.prepare_bridge(&request, &secrets).unwrap();
				interrupted.submit().await.unwrap();
				while storage.staging_writes.get() != 2 {
					environment::yield_turn().await;
				}
				assert_eq!(calls.get(), 1, "credential write precedes submission");
				let premature = workspace
					.prepare_forget_bridge(workspace.snapshot().await.unwrap().revision, "room")
					.await
					.unwrap();
				assert!(
					premature.submit().await.is_err(),
					"forgetting cannot abandon an admitted bridge worker"
				);
				platform.tasks.borrow().last().unwrap().abort();
				for _ in 0..3 {
					environment::yield_turn().await;
				}
				owner.resume_pending().unwrap();
				storage.held.set(false);
				assert_eq!(terminal(&interrupted).await, EffectStatus::Committed);
				assert_eq!(
					storage.staging_writes.get(),
					2,
					"interruption preserves the original document observation"
				);
				assert_eq!(
					calls.get(),
					2,
					"one target dispatch follows the original credential write"
				);
				let replacement = Workspace::local(host.clone(), platform.clone(), other.clone());
				assert!(
					replacement
						.prepare_bridge_reapplication(
							"substitute",
							replacement.snapshot().await.unwrap().revision,
							"room"
						)
						.await
						.is_err()
				);
				assert!(
					Workspace::local(host.clone(), platform.clone(), root.clone())
						.prepare_bridge_reapplication("stronger", workspace.snapshot().await.unwrap().revision, "room")
						.await
						.is_err()
				);
				// A new seat through the same continuing access retains the original
				// form and saved identity, independently of original receipt eviction.
				let workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
					panic!("room")
				};
				room.seat = Some(seat_key(2));
				owner.replace_workspace(&intent).await.unwrap();
				for i in 0..9 {
					let snapshot = workspace.snapshot().await.unwrap();
					workspace
						.prepare_command(
							&format!("evict-{i}"),
							snapshot.revision,
							"setStanding",
							&[format!("standing-{i}")],
						)
						.await
						.unwrap()
						.submit()
						.await
						.unwrap();
				}
				let reapply = workspace
					.prepare_bridge_reapplication("reapply", workspace.snapshot().await.unwrap().revision, "room")
					.await
					.unwrap();
				assert_eq!(reapply.submit().await.unwrap(), EffectStatus::Pending);
				assert_eq!(terminal(&reapply).await, EffectStatus::Committed);
				assert_eq!(calls.get(), 3);
				let original = intent.clone();
				let workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
					panic!("room")
				};
				room.access = Some(custody::FieldKey::new(
					NonZeroU64::new(2).unwrap(),
					NonZeroU64::new(1).unwrap(),
				));
				owner.replace_workspace(&intent).await.unwrap();
				assert!(
					workspace
						.prepare_bridge_reapplication(
							"successor-access",
							workspace.snapshot().await.unwrap().revision,
							"room"
						)
						.await
						.is_err()
				);
				intent = original;
				owner.replace_workspace(&intent).await.unwrap();
				// Form declaration changes refuse before any saved credential leaves.
				let mut changed = form();
				changed.scope = Text::new("successor-form".into()).unwrap();
				*current_form.borrow_mut() = changed;
				let changed = workspace
					.prepare_bridge_reapplication("changed-form", workspace.snapshot().await.unwrap().revision, "room")
					.await
					.unwrap();
				changed.submit().await.unwrap();
				assert_eq!(terminal(&changed).await, EffectStatus::Unsent);
				assert_eq!(calls.get(), 3);
				*current_form.borrow_mut() = form();
				lifecycle(&host, &control, "pause").await;
				assert!(
					workspace
						.prepare_bridge_reapplication("paused", 1, "room")
						.await
						.is_err()
				);
				lifecycle(&host, &control, "resume").await;
				// A succeeded previous identity cannot justify replay of a newer
				// first submission whose effect returned an unrecognized result.
				unknown.set(true);
				request.operation = Text::new("unknown-first".into()).unwrap();
				request.base = SafeInteger::new(workspace.snapshot().await.unwrap().revision).unwrap();
				request.seat = seat_key(2);
				let unknown_command = workspace.prepare_bridge(&request, &secrets).unwrap();
				unknown_command.submit().await.unwrap();
				assert_eq!(terminal(&unknown_command).await, EffectStatus::Unknown);
				assert_eq!(calls.get(), 4);
				owner.resume_pending().unwrap();
				for _ in 0..4 {
					environment::yield_turn().await;
				}
				assert!(
					workspace
						.prepare_bridge_reapplication(
							"unknown-retry",
							workspace.snapshot().await.unwrap().revision,
							"room"
						)
						.await
						.is_err()
				);
				assert_eq!(calls.get(), 4);
				unknown.set(false);
				for accepted in [true, false] {
					let workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
						panic!("room")
					};
					room.access = None;
					room.accepted = accepted
						.then(|| custody::FieldKey::new(NonZeroU64::new(1).unwrap(), NonZeroU64::new(1).unwrap()));
					room.public_entry = (!accepted).then(|| workspace::PublicEntry {
						access: custody::FieldKey::new(NonZeroU64::new(1).unwrap(), NonZeroU64::new(1).unwrap()),
					});
					room.publication = (!accepted).then(|| Text::new("exact-publication".into()).unwrap());
					owner.replace_workspace(&intent).await.unwrap();
					request.operation =
						Text::new(if accepted { "accepted-visit" } else { "public-visit" }.into()).unwrap();
					request.access = accepted.then(|| coordinate(custody::Role::AcceptedAccess, 1));
					request.base = SafeInteger::new(workspace.snapshot().await.unwrap().revision).unwrap();
					let visit = workspace.prepare_bridge(&request, &secrets).unwrap();
					visit.submit().await.unwrap();
					assert_eq!(terminal(&visit).await, EffectStatus::Committed);
					assert!(
						workspace
							.prepare_bridge_reapplication(
								"visit-reapply",
								workspace.snapshot().await.unwrap().revision,
								"room"
							)
							.await
							.is_err(),
						"a visit cannot justify credential reapplication"
					);
				}
				assert_eq!(calls.get(), 6);
				let forgetting = workspace
					.prepare_forget_bridge(workspace.snapshot().await.unwrap().revision, "room")
					.await
					.unwrap();
				forgetting.submit().await.unwrap();
				forgetting.submit().await.unwrap();
				loop {
					let encoded: serde_json::Value =
						serde_json::from_slice(storage.bytes.borrow().as_ref().unwrap()).unwrap();
					if encoded["pending"].as_array().unwrap().is_empty()
						&& encoded["secrets"].as_array().unwrap().is_empty()
					{
						break;
					}
					environment::yield_turn().await;
				}
				assert!(
					workspace
						.prepare_bridge_reapplication("forgotten", workspace.snapshot().await.unwrap().revision, "room")
						.await
						.is_err()
				);
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop((
					workspace,
					replacement,
					command,
					interrupted,
					reapply,
					changed,
					unknown_command,
					premature,
					forgetting,
					owner,
					attachment,
				));
				environment::close(&mut store).await;
				database.remove();
			})
			.await
			.expect("bridge origin journey deadline");
		})
		.await;
}
