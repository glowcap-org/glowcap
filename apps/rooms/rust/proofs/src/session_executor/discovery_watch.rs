//! The real managed worker admits observation without membership authority,
//! fences notifications and retains exact cleanup after source revocation.
use super::*;
use rooms_application::{
	content::{permissions::Permission, session::workspace},
	directory,
	fields::Text,
};
use rooms_glowcap::client::workspace::Workspace;
use std::cell::RefCell;
mod resynchronization;
mod undialable;

fn key<K>(value: u64) -> custody::FieldKey<K> {
	custody::FieldKey::new(NonZeroU64::new(value).unwrap(), NonZeroU64::new(1).unwrap())
}

/// Counts every restoration asked of one saved coordinate: each is a dial of
/// the address it names.
struct CountRestorations {
	inner: Box<dyn Content>,
	coordinate: String,
	count: Rc<Cell<usize>>,
}
impl Content for CountRestorations {
	fn dependent_requirement(&self, input: Invocation<'_>) -> Result<Requirement> {
		self.inner.dependent_requirement(input)
	}
	fn requirement(&self, input: Invocation<'_>) -> Result<Requirement> {
		self.inner.requirement(input)
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<loam::ReferenceRequest>> {
		let asked = input.verb == "restore-custody"
			&& input
				.args
				.get(1)
				.and_then(Argument::as_list)
				.is_some_and(|items| items.iter().any(|item| item.as_str() == Some(self.coordinate.as_str())));
		if asked {
			self.count.set(self.count.get() + 1);
		}
		self.inner.references(input)
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		self.inner.invoke(call, input)
	}
}

#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn discovery_admits_observation_only_and_retires_exact_observer_after_source_revocation() {
	run().await;
}

pub(super) async fn run() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let database = Database::new("discovery-watch");
				let mut store = database
					.open(true, &managed::schemas(), managed::production_limits().unwrap())
					.await;
				let policy = rooms_glowcap::policy::descriptor().unwrap();
				let resource = environment::create(
					&store,
					&policy,
					managed::schemas()[0],
					&managed::initial_payload(rooms_application::content::session::workspace::Connection::Relay)
						.unwrap(),
					3,
				)
				.await;
				let host = Host::from_seed([171; 32]).unwrap();
				let platform = Platform::default();
				let owner = managed::Session::new(
					host.clone(),
					platform.clone(),
					std::num::NonZeroUsize::new(256 * 1024).unwrap(),
				);
				let stale_access = requests::coordinate(custody::Role::DirectoryAccess, 3);
				let dials = Rc::new(Cell::new(0));
				let mut registration = owner.registration();
				registration.content = Box::new(CountRestorations {
					inner: registration.content,
					coordinate: serde_json::to_string(&stale_access).unwrap(),
					count: dials.clone(),
				});
				let mut attachment = store.attach(&host, vec![registration]).unwrap();
				environment::start_live(&attachment, None, 64).await;
				let (root, root_control) = environment::restore(&attachment, resource).await;
				owner.bind(root.clone(), root_control.clone()).unwrap();
				owner.initialize().await.unwrap();
				let terms = policy
					.value_for_kind(session::KIND, &[Permission::ObserveWorkspace.key()], &[])
					.unwrap();
				let (source, control) = owner
					.derive(
						terms,
						0,
						ControlPowers {
							pause: true,
							resume: true,
							revoke: true,
							..Default::default()
						},
					)
					.await
					.unwrap();
				let state = Rc::new(RefCell::new(
					rooms_application::server::directory::Directory::<u64, Ref>::default(),
				));
				let refuse_cancel = Rc::new(Cell::new(false));
				let watches = Rc::new(Cell::new(0));
				let exporter = Host::from_seed([172; 32]).unwrap();
				exporter
					.publish("discovery-directory", {
						let state = state.clone();
						let refuse = refuse_cancel.clone();
						let count = watches.clone();
						move || {
							let state = state.clone();
							let refuse = refuse.clone();
							let count = count.clone();
							Box::new(move |verb, args| {
								let verb = verb.ok_or("fixture requires a method")?;
								let [Argument::Reference(observer)] = args else {
									return Err("exact observer required".into());
								};
								match verb {
									directory::WATCH => {
										count.set(count.get() + 1);
										let (snapshot, _) = state
											.borrow_mut()
											.watch(
												1,
												observer.clone(),
												directory::Shape::Publication,
												core::iter::empty(),
											)
											.unwrap();
										Ok(directory::wire::snapshot::<rooms_glowcap::Arguments>(
											&snapshot,
											directory::Shape::Publication,
										))
									}
									directory::UNWATCH => {
										if refuse.get() {
											return Err("cancel temporarily refused".into());
										}
										state.borrow_mut().unwatch(1, observer);
										Ok(Argument::Void)
									}
									_ => Err("unknown directory method".into()),
								}
							})
						}
					})
					.unwrap();
				let access = requests::coordinate(custody::Role::DirectoryAccess, 1);
				let bootstrap = exporter.spawn(|_, _| Ok(Argument::Void)).unwrap();
				let (client, accepted) = management::connect(&exporter, &host, &bootstrap).await;
				let target = client.session().fetch("discovery-directory").await.unwrap();
				let initiating = requests::coordinate(custody::Role::SessionAccess, 2);
				let uri = glowcap::format_sturdyref(
					&glowcap::Locator::bare("tcp", "127.0.0.1:9149"),
					b"discovery-directory",
					glowcap::CaptpVersion::V1_0,
				)
				.unwrap();
				owner.import(access, target.clone(), Some(uri)).await.unwrap();
				owner.import(initiating, source.clone(), None).await.unwrap();
				// A membership realizes through a source with the session's full
				// authority. The observe-only source above keeps this proof's thesis.
				let supported: Vec<_> = session::SUPPORTED.iter().map(|p| p.key()).collect();
				let full = policy.value_for_kind(session::KIND, &supported, &[]).unwrap();
				let (member_source, _) = owner.derive(full, 0, ControlPowers::default()).await.unwrap();
				owner
					.import(
						requests::coordinate(custody::Role::SessionAccess, 4),
						member_source,
						None,
					)
					.await
					.unwrap();
				// A directory saved at a door this Host dials no connector for once
				// the session that imported it has ended.
				let stale_exporter = Host::from_seed([173; 32]).unwrap();
				stale_exporter
					.publish("stale-directory", || Box::new(|_, _| Ok(Argument::Void)))
					.unwrap();
				let stale_locator = glowcap::Locator::bare("tcp", "127.0.0.1:9150");
				let (left, right) = tokio::io::duplex(8192);
				let (stale_client, stale_accepted) = tokio::join!(
					glowcap::Session::dial_over(&host, &stale_locator, left, Some(std::time::Duration::from_secs(2))),
					glowcap::Session::accept_over(
						&stale_exporter,
						"tcp",
						"127.0.0.1:9150",
						"127.0.0.1:9151",
						right,
						Some(std::time::Duration::from_secs(2))
					)
				);
				let (stale_client, stale_accepted) = (stale_client.unwrap(), stale_accepted.unwrap());
				let stale_target = stale_client.fetch("stale-directory").await.unwrap();
				let stale_uri =
					glowcap::format_sturdyref(&stale_locator, b"stale-directory", glowcap::CaptpVersion::V1_0).unwrap();
				owner
					.import(stale_access, stale_target.clone(), Some(stale_uri))
					.await
					.unwrap();
				drop(stale_target);
				stale_client.close(PendingWork::Cancel).await.unwrap();
				drop(stale_accepted);
				stale_exporter.close(PendingWork::Cancel).await.unwrap();
				let row = workspace::Directory {
					id: Text::new("directory".into()).unwrap(),
					access: key(1),
					source: Some(key(2)),
					name: None,
					inbox: None,
					home: true,
					nick: Text::new("".into()).unwrap(),
					assigned_nick: None,
					nick_allocation: directory::registration::NicknameAllocation::Exact,
					standing: None,
				};
				let mut stale = row.clone();
				stale.id = Text::new("stale".into()).unwrap();
				stale.access = key(3);
				stale.home = false;
				let mut intent = Intent::empty();
				intent.directories = List::new(vec![row.clone()]).unwrap();
				let mut both = Intent::empty();
				both.directories = List::new(vec![row.clone(), stale.clone()]).unwrap();
				owner.replace_workspace(&intent).await.unwrap();
				let workspace = Workspace::local(host.clone(), platform.clone(), source.clone());
				let selected = workspace::DiscoverySelection::directory(&row).unwrap();
				workspace.check_discovery(&selected).await.unwrap();
				let (other, _) = owner.derive(terms, 0, ControlPowers::default()).await.unwrap();
				assert!(
					Workspace::local(host.clone(), platform.clone(), other.clone())
						.check_discovery(&selected)
						.await
						.is_err()
				);
				let notifications = Rc::new(Cell::new(0));
				let mut view = owner
					.watch_directory(&row, {
						let notifications = notifications.clone();
						move |_, _| {
							notifications.set(notifications.get() + 1);
							Ok(())
						}
					})
					.await
					.unwrap();
				let snapshot = view.snapshot().await.unwrap();
				view.accept_snapshot();
				assert!(snapshot.rooms.is_empty() && snapshot.peers.is_empty());
				assert_eq!(
					state.borrow().registered_nick(1),
					None,
					"observation never registers a member"
				);
				assert!(owner.watch_directory(&row, |_, _| Ok(())).await.is_err());
				let callback = state.borrow().watchers().next().unwrap().1.clone();
				let event = ["count".into(), "room".into(), 1.into()];
				exporter.send(&callback, "notify", &event).await.unwrap();
				assert_eq!(notifications.get(), 1);
				publication_results::lifecycle(&host, &control, "pause").await;
				assert!(exporter.send(&callback, "notify", &event).await.is_err());
				assert_eq!(notifications.get(), 1);
				publication_results::lifecycle(&host, &control, "resume").await;
				exporter.send(&callback, "notify", &event).await.unwrap();
				assert_eq!(notifications.get(), 2);
				view.close().await.unwrap();
				undialable::run(&owner, &workspace, &both, &stale, &dials).await;
				owner.replace_workspace(&intent).await.unwrap();
				resynchronization::run(&owner, &workspace, &exporter, &state, &watches, &refuse_cancel).await;
				view = owner.watch_directory(&row, |_, _| Ok(())).await.unwrap();
				view.snapshot().await.unwrap();
				view.accept_snapshot();
				let callback = state.borrow().watchers().next().unwrap().1.clone();
				let admitted_watches = watches.get();
				// Exact selection retirement is permanent. Revocation below
				// cancels this observer instead of reviving it under another row.
				refuse_cancel.set(true);
				publication_results::lifecycle(&host, &control, "revoke").await;
				assert!(exporter.send(&callback, "notify", &event).await.is_err());
				assert!(view.close().await.is_err());
				assert_eq!(
					state.borrow().watchers().count(),
					1,
					"failed cleanup retains its exact target"
				);
				refuse_cancel.set(false);
				view.close().await.unwrap();
				assert_eq!(state.borrow().watchers().count(), 0);
				assert_eq!(
					watches.get(),
					admitted_watches,
					"retirement retry never registers another observer"
				);
				assert!(exporter.send(&callback, "notify", &event).await.is_err());
				drop((
					view,
					workspace,
					callback,
					target,
					other,
					source,
					control,
					root,
					root_control,
				));
				owner.close().await.unwrap();
				attachment.close().await.unwrap();
				drop((client, accepted, bootstrap));
				exporter.close(PendingWork::Cancel).await.unwrap();
				drop((attachment, owner));
				host.close(PendingWork::Cancel).await.unwrap();
				environment::close(&mut store).await;
				drop(store);
				database.remove();
			})
			.await
			.expect("bounded managed discovery journey");
		})
		.await;
}
