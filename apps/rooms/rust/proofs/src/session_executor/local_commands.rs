//! Local intent and its terminal receipt commit together, including rollback
//! and cold replay. Revoked upstream authority cannot gate a local gesture.
use super::*;
use rooms_application::{content::permissions::Permission, content::session::workspace};
mod selection;

struct Audit {
	inner: Box<dyn Content>,
	refuse: Rc<Cell<bool>>,
	requests: Rc<Cell<usize>>,
}
impl Content for Audit {
	fn requirement(&self, input: Invocation<'_>) -> Result<Requirement> {
		self.inner.requirement(input)
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<loam::ReferenceRequest>> {
		let requests = self.inner.references(input)?;
		if input.verb == "command" {
			self.requests.set(requests.len());
		}
		Ok(requests)
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		let result = self.inner.invoke(call, input)?;
		if input.verb == "command" && self.refuse.get() {
			return Err(loam::refusal("refuse after local candidate and receipt staging"));
		}
		Ok(result)
	}
}
async fn snapshot(host: &Host, source: &Ref) -> (i64, Intent) {
	let answer = host.send(source, "snapshot", &[]).await.unwrap();
	let [revision, intent] = answer.as_list().unwrap() else {
		panic!("workspace snapshot");
	};
	(
		revision.as_i64().unwrap(),
		Intent::decode(intent.as_str().unwrap()).unwrap(),
	)
}
fn args(id: &str, revision: i64, command: &str, rest: &[&str]) -> Vec<Argument> {
	let mut args = vec![id.into(), revision.into(), command.into()];
	args.extend(rest.iter().copied().map(Argument::from));
	args
}
async fn gesture(host: &Host, source: &Ref, id: &str, command: &str, rest: &[&str]) -> Intent {
	let (revision, _) = snapshot(host, source).await;
	assert_eq!(
		mutate(host, source, "command", &args(id, revision, command, rest))
			.await
			.unwrap()
			.as_str(),
		Some("committed")
	);
	snapshot(host, source).await.1
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn local_gestures_commit_atomically_and_replay_original_source_after_cold_restart() {
	run().await;
}
pub(super) async fn run() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new("local-commands");
				let mut schemas = managed::schemas();
				schemas.push(TARGET);
				let mut limits = crate::session_storage::limits_for(
					24,
					8,
					loam::ValueBounds {
						values: 32,
						capabilities: 4,
						bytes: 8192,
						..Default::default()
					},
				);
				// Cold restoration and its enclosing derivation keep independent
				// leases over shared rows, within the declared operation population.
				limits.max_leases = limits.max_leases.checked_mul(limits.max_operations).unwrap();
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
				let upstream = environment::create(&store, &policy, TARGET, b"original", 1).await;
				let host = Host::from_seed([115; 32]).unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(8192).unwrap(),
				);
				let calls = Rc::new(Cell::new(0));
				let refuse = Rc::new(Cell::new(false));
				let requests = Rc::new(Cell::new(usize::MAX));
				let mut registration = owner.registration();
				registration.content = Box::new(Audit {
					inner: registration.content,
					refuse: refuse.clone(),
					requests: requests.clone(),
				});
				let case = Case::operator();
				let mut attachment = store
					.attach(
						&host,
						vec![
							registration,
							target_registration(calls.clone(), Rc::new(Cell::new(false)), &case),
						],
					)
					.unwrap();
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				let (target, target_control) = environment::restore(&attachment, upstream).await;
				for role in [custody::Role::DirectoryAccess, custody::Role::RoomAccess] {
					owner
						.import(custody::Coordinate { role, key: key() }, target.clone(), None)
						.await
						.unwrap();
				}
				let spare = custody::Coordinate {
					role: custody::Role::RoomAccess,
					key: custody::FieldKey::new(NonZeroU64::new(2).unwrap(), NonZeroU64::new(1).unwrap()),
				};
				owner.import(spare, target.clone(), None).await.unwrap();
				let mut initial = Case::kick().workspace(1);
				let workspace::Conversation::Room(room) = &mut initial.conversations.as_mut_slice()[0] else {
					panic!("room");
				};
				room.moderator = None;
				room.access = Some(key());
				owner.replace_workspace(&initial).await.unwrap();
				let renamed = gesture(
					&host,
					&root,
					"nickname",
					"chooseDirectoryNickname",
					&["directory", "new-name", "automatic"],
				)
				.await;
				assert_eq!(renamed.directories.as_slice()[0].nick.text().as_str(), Some("new-name"));
				assert_eq!(
					renamed.directories.as_slice()[0].nick_allocation,
					rooms_application::directory::registration::NicknameAllocation::Automatic
				);
				assert_eq!(
					requests.get(),
					0,
					"nickname choice cannot call an upstream registration directly"
				);
				let unnamed = gesture(
					&host,
					&root,
					"release-nickname",
					"chooseDirectoryNickname",
					&["directory", "", "exact"],
				)
				.await;
				assert_eq!(unnamed.directories.as_slice()[0].nick.text().as_str(), Some(""));

				let terms = policy
					.value_for_kind(
						session::KIND,
						&[Permission::ObserveWorkspace.key(), Permission::InteractWorkspace.key()],
						&[],
					)
					.unwrap();
				let powers = ControlPowers {
					policy_ceiling: Some(terms),
					pause: true,
					resume: true,
					revoke: true,
					..Default::default()
				};
				let sequence = host
					.send(&root, "derivation-sequence", &[])
					.await
					.unwrap()
					.as_i64()
					.unwrap() as u32;
				let source_derivation = terms.managed_derive_arguments(sequence, 1, powers);
				let (source, control) = owner.derive(terms, 1, powers).await.unwrap();
				let other_derivation = terms.managed_derive_arguments(sequence + 1, 1, powers);
				let (other, _) = owner.derive(terms, 1, powers).await.unwrap();
				let observe = policy
					.value_for_kind(session::KIND, &[Permission::ObserveWorkspace.key()], &[])
					.unwrap();
				let (observer, _) = owner.derive(observe, 1, ControlPowers::default()).await.unwrap();
				host.send(
					&target_control,
					"revoke",
					&[Argument::Bytes(
						glowcap::loam::control_revision(&host, &target_control)
							.await
							.unwrap()
							.to_be_bytes()
							.to_vec(),
					)],
				)
				.await
				.unwrap();
				let selections =
					selection::run(&host, &owner, &root, &policy, &source, &target, (&refuse, &requests)).await;
				let (base, before) = snapshot(&host, &source).await;
				let command = args("local-draft", base, "setDraft", &["conversation", "first draft"]);
				assert!(mutate(&host, &observer, "command", &command).await.is_err());
				host.send(
					&control,
					"pause",
					&[Argument::Bytes(
						glowcap::loam::control_revision(&host, &control)
							.await
							.unwrap()
							.to_be_bytes()
							.to_vec(),
					)],
				)
				.await
				.unwrap();
				assert!(mutate(&host, &source, "command", &command).await.is_err());
				host.send(
					&control,
					"resume",
					&[Argument::Bytes(
						glowcap::loam::control_revision(&host, &control)
							.await
							.unwrap()
							.to_be_bytes()
							.to_vec(),
					)],
				)
				.await
				.unwrap();
				refuse.set(true);
				assert!(mutate(&host, &source, "command", &command).await.is_err());
				assert_eq!(snapshot(&host, &source).await, (base, before));
				assert_eq!(requests.get(), 0, "new local admission restores no upstream fields");
				refuse.set(false);
				assert_eq!(
					mutate(&host, &source, "command", &command).await.unwrap().as_str(),
					Some("committed")
				);
				assert_eq!(requests.get(), 0);
				let (revision, changed) = snapshot(&host, &source).await;
				assert!(revision > base);
				let workspace::Conversation::Room(room) = &changed.conversations.as_slice()[0] else {
					panic!("room");
				};
				assert_eq!(room.draft.text().as_str(), Some("first draft"));
				assert!(
					mutate(&host, &other, "command", &command).await.is_err(),
					"equal terms cannot recover another source's receipt"
				);
				assert!(
					mutate(
						&host,
						&source,
						"command",
						&args("local-draft", base, "setDraft", &["conversation", "substitute"])
					)
					.await
					.is_err()
				);
				assert_eq!(
					mutate(
						&host,
						&source,
						"command",
						&args("stale", base, "setStanding", &["stale"])
					)
					.await
					.unwrap()
					.as_str(),
					Some("conflict")
				);
				assert_eq!(snapshot(&host, &source).await, (revision, changed));
				assert_eq!(
					mutate(&host, &source, "command", &command).await.unwrap().as_str(),
					Some("committed")
				);
				assert_eq!(requests.get(), 1, "replay restores only original source");
				assert_eq!(
					snapshot(&host, &source).await.0,
					revision,
					"semantic replay stages no new content"
				);
				let current = gesture(
					&host,
					&source,
					"later-draft",
					"setDraft",
					&["conversation", "later draft"],
				)
				.await;
				assert_eq!(
					mutate(&host, &source, "command", &command).await.unwrap().as_str(),
					Some("committed")
				);
				assert_eq!(
					snapshot(&host, &source).await.1,
					current,
					"old receipt cannot reapply old intent"
				);
				let canonical =
					serde_json::to_string(&("local-draft", base, "setDraft", ["conversation", "first draft"])).unwrap();
				let result = host
					.send(
						&source,
						"effect-result",
						&["local-draft".into(), canonical.clone().into()],
					)
					.await
					.unwrap();
				assert_eq!(result.as_str(), Some("null"));
				assert!(platform.tasks.borrow().is_empty(), "local commits allocate no worker");
				assert_eq!(calls.get(), 0);
				let (revision, _) = snapshot(&host, &source).await;
				let departure = args("local-departure", revision, "leaveDirectory", &["directory"]);
				refuse.set(true);
				assert!(mutate(&host, &source, "command", &departure).await.is_err());
				assert_eq!(snapshot(&host, &source).await, (revision, current));
				refuse.set(false);
				assert_eq!(
					mutate(&host, &source, "command", &departure).await.unwrap().as_str(),
					Some("committed")
				);
				assert_eq!(requests.get(), 0, "departure restores no upstream fields");
				let current = snapshot(&host, &source).await.1;
				assert!(current.directories.is_empty() && current.conversations.is_empty() && current.active.is_none());
				for role in [custody::Role::DirectoryAccess, custody::Role::RoomAccess] {
					let coordinate = custody::Coordinate { role, key: key() };
					assert!(
						mutate(
							&host,
							&root,
							"release",
							&[
								serde_json::to_string(&coordinate).unwrap().into(),
								serde_json::to_string(&current).unwrap().into()
							]
						)
						.await
						.is_err(),
						"departed custody is absent"
					);
				}
				assert!(platform.tasks.borrow().is_empty());
				assert_eq!(calls.get(), 0);
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop(attachment);
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				let mut store = database.open(false, &schemas, limits).await;
				let host = Host::from_seed([115; 32]).unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(8192).unwrap(),
				);
				let calls = Rc::new(Cell::new(0));
				let mut attachment = store
					.attach(
						&host,
						vec![
							owner.registration(),
							target_registration(calls.clone(), Rc::new(Cell::new(false)), &case),
						],
					)
					.unwrap();
				let (root, root_control) =
					environment::restore(&attachment, loam::Resource::decode(resource.encode())).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				// Shared derivation receipt replay restores the original grants.
				// The private root does not issue replacement recovery authority.
				let restored = host.send(&root, "derive-managed", &source_derivation).await.unwrap();
				let source = Ref::try_from(&restored.as_list().unwrap()[0]).unwrap();
				let restored = host.send(&root, "derive-managed", &other_derivation).await.unwrap();
				let other = Ref::try_from(&restored.as_list().unwrap()[0]).unwrap();
				assert_eq!(
					mutate(&host, &source, "command", &command).await.unwrap().as_str(),
					Some("committed")
				);
				assert_eq!(snapshot(&host, &source).await.1, current);
				selections.replay(&host, &root, &source).await;
				assert_eq!(
					mutate(&host, &source, "command", &departure).await.unwrap().as_str(),
					Some("committed")
				);
				mutate(
					&host,
					&root,
					"release",
					&[
						serde_json::to_string(&spare).unwrap().into(),
						serde_json::to_string(&current).unwrap().into(),
					],
				)
				.await
				.unwrap();
				assert_eq!(
					host.send(&source, "effect-result", &["local-draft".into(), canonical.into()])
						.await
						.unwrap(),
					result
				);
				assert!(mutate(&host, &other, "command", &command).await.is_err());
				let changed = gesture(&host, &source, "standing", "setStanding", &["away"]).await;
				assert_eq!(changed.standing.text().as_str(), Some("away"));
				assert!(platform.tasks.borrow().is_empty());
				assert_eq!(calls.get(), 0);
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				drop(attachment);
				drop(owner);
				environment::close(&mut store).await;
				drop(store);
				database.remove();
			})
			.await
			.expect("bounded local command proof");
		})
		.await;
}
