//! Exact signaling registrations retain ownership through observation failure.
use super::{Membership, Session, supervision};
use glowcap::{Argument, Result, loam};
use rooms_application::content::{
	permissions::Permission,
	session::{custody, workspace},
};
use rooms_glowcap::client::{Deadline, Tasks, directory::signaling::Route};
use std::collections::BTreeMap;

pub struct SignalingRegistration<P: Tasks + Deadline> {
	lifetime: Membership<P>,
	route: Route<P>,
}
impl<P: Tasks + Deadline> SignalingRegistration<P> {
	pub fn status(&self) -> Option<Result<()>> {
		self.lifetime.status()
	}
	pub async fn ready(&self) -> Result<()> {
		self.lifetime.ready().await
	}
	pub fn retry(&self) {
		self.lifetime.retry();
	}
	pub fn route(&self) -> &Route<P> {
		&self.route
	}
	pub async fn retired(&self) {
		let _ = self.lifetime.ended().await;
	}
	pub async fn close(&mut self) -> Result<()> {
		self.lifetime.close().await
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Session<P> {
	/// The embedding chooses its own advertised transport from committed intent.
	/// This private owner read grants no membership or signaling authority. Those
	/// operations still check the public observer and each saved initiating source.
	pub async fn connection_choice(&self) -> Result<workspace::Connection> {
		Ok(rooms_glowcap::client::workspace::Workspace::local(
			self.state.writer.host.clone(),
			self.state.platform.clone(),
			self.state.writer.root()?,
		)
		.snapshot()
		.await
		.map_err(error)?
		.intent
		.connection)
	}
	/// The checked signaling route through one directory this session is a
	/// named member of, bound to the directory's session as its introducer. A
	/// dial carries its offer, answer and candidates through it. The route is
	/// checked once here, and the directory refuses a later exchange itself
	/// when the name has expired or been replaced.
	pub async fn signaling_route(&self, row: &workspace::Directory) -> Result<Route<P>> {
		let selected = workspace::SignalingSelection::directory(row)
			.ok_or_else(|| loam::refusal("signaling has no exact registered name and source"))?;
		let source = self.directory_source(row).await?;
		let mut route = source.workspace().signaling(&selected).await.map_err(error)?;
		let directory = self
			.restore_custody(&[custody::Coordinate {
				role: custody::Role::DirectoryAccess,
				key: custody::FieldKey::new(row.access.slot(), row.access.generation()),
			}])
			.await?
			.remove(0);
		route.retain_introducer(&directory).map_err(error)?;
		route.check().await.map_err(error)?;
		Ok(route)
	}
	pub async fn signaling_registration(&self, row: &workspace::Directory) -> Result<SignalingRegistration<P>> {
		let _permit = supervision::Permit::reserve(&self.state.signaling_observers)?;
		let selected = workspace::SignalingSelection::directory(row)
			.ok_or_else(|| loam::refusal("signaling has no exact registered name and source"))?;
		let id = format!(
			"signaling-{}",
			row.id
				.text()
				.as_str()
				.ok_or_else(|| loam::refusal("invalid signaling directory"))?
		);
		if self.state.closing.get() || self.state.signaling_observers.contains(&id) {
			return Err(loam::refusal("signaling is closing or already supervised"));
		}
		let source = self.directory_source(row).await?;
		let route = self.signaling_route(row).await?;
		// Concurrent startups may have installed this identity while we waited.
		if self.state.closing.get() || self.state.signaling_observers.contains(&id) {
			return Err(loam::refusal("signaling is closing or already supervised"));
		}
		let mut changes = self.state.changes.subscribe(&self.state)?;
		let checking = route.clone();
		let writer = self.state.writer.clone();
		let workspace = source.workspace().clone();
		let platform = self.state.platform.clone();
		let lifetime = supervision::spawn(
			&self.state.platform,
			&self.state.signaling_observers,
			id,
			None,
			move |mut signals| async move {
				loop {
					if *signals.stopping.borrow_and_update() {
						return Ok(());
					}
					let checked = tokio::select! { biased;
						_ = signals.stopping.changed() => return Ok(()),
						checked = platform.within(20_000, async {
							changes.ready().await?;
							let encoded = serde_json::to_string(&selected)
								.map_err(|_| loam::refusal("invalid signaling selection"))?;
							match writer.idempotent("signaling-selected", &[encoded.into()]).await? {
								Argument::Boolean(false) => return Ok(false),
								Argument::Boolean(true) => {},
								_ => return Err(loam::refusal("invalid signaling selection acknowledgment")),
							}
							let description = writer.idempotent_through(workspace.reference(), "describe-access", &[]).await?;
							let active = match loam::UseDescription::read(&description)? {
								loam::UseDescription::Active(source) => source.effective.permissions()
									.any(|permission| permission == Permission::InteractWorkspace.key()),
								_ => false,
							};
							if !active { return Ok(false); }
							checking.check().await.map_err(error)?;
							Ok(true)
						}) => checked.unwrap_or_else(|| Err(loam::refusal("signaling source check is still unresolved"))),
					};
					let failed = match checked {
						// Only affirmative source/selection evidence releases this owner.
						Ok(false) => return Ok(()),
						Err(failure) => Some(failure),
						Ok(true) => {
							signals.ready.send_replace(Some(Ok(())));
							tokio::select! { biased;
								_ = signals.stopping.changed() => return Ok(()),
								_ = signals.retrying.changed() => { changes.retry(); continue; },
								changed = changes.changed() => changed.err(),
							}
						}
					};
					if let Some(failure) = failed {
						writer.report("Signaling supervision", &failure);
						signals.ready.send_replace(Some(Err(failure)));
						// Capacity, transport and feed failures retain the same watcher.
						// Retry wakes the existing shared feeds, never a new registration.
						tokio::select! { biased;
							_ = signals.stopping.changed() => return Ok(()),
							_ = signals.retrying.changed() => changes.retry(),
						}
					}
				}
			},
		);
		Ok(SignalingRegistration { lifetime, route })
	}
	/// Keep one checked signaling route per directory this session is a named
	/// member of, for dials this session's Host makes through those
	/// directories. `publish` receives the whole set, keyed by directory row id,
	/// each time it changes. A route the directory refuses is reported through
	/// the session's trouble report and tried again when the workspace changes
	/// or a retry is asked for. Close the returned membership before the
	/// session, as with every other supervised job.
	pub fn follow_signaling_routes(
		&self,
		publish: impl Fn(BTreeMap<String, Route<P>>) + 'static,
	) -> Result<Membership<P>> {
		let _permit = supervision::Permit::reserve(&self.state.signaling_observers)?;
		let id = "signaling-routes".to_owned();
		if self.state.closing.get() || self.state.signaling_observers.contains(&id) {
			return Err(loam::refusal("signaling routes are closing or already followed"));
		}
		let mut changes = self.state.changes.subscribe(&self.state)?;
		let session = Session {
			state: self.state.clone(),
		};
		let workspace = rooms_glowcap::client::workspace::Workspace::local(
			self.state.writer.host.clone(),
			self.state.platform.clone(),
			self.state.writer.root()?,
		);
		Ok(supervision::spawn(
			&self.state.platform,
			&self.state.signaling_observers,
			id,
			None,
			move |mut signals| async move {
				let mut held = BTreeMap::<String, (workspace::SignalingSelection, Route<P>)>::new();
				loop {
					if *signals.stopping.borrow_and_update() {
						return Ok(());
					}
					let followed = async {
						changes.ready().await?;
						let intent = workspace.snapshot().await.map_err(error)?.intent;
						let mut selected = BTreeMap::new();
						for row in intent.directories.as_slice() {
							if let Some(selection) = workspace::SignalingSelection::directory(row) {
								let id = row
									.id
									.text()
									.as_str()
									.ok_or_else(|| loam::refusal("invalid directory"))?;
								selected.insert(id.to_owned(), (selection, row.clone()));
							}
						}
						held.retain(|id, held| selected.get(id).is_some_and(|(now, _)| *now == held.0));
						for (id, (selection, row)) in selected {
							if held.contains_key(&id) {
								continue;
							}
							match session.signaling_route(&row).await {
								Ok(route) => {
									held.insert(id, (selection, route));
								}
								Err(failure) => session.state.writer.report("Signaling routes", &failure),
							}
						}
						publish(
							held.iter()
								.map(|(id, (_, route))| (id.clone(), route.clone()))
								.collect(),
						);
						Ok::<(), glowcap::Error>(())
					}
					.await;
					let failed = match followed {
						Err(failure) => Some(failure),
						Ok(()) => {
							signals.ready.send_replace(Some(Ok(())));
							tokio::select! { biased;
								_ = signals.stopping.changed() => return Ok(()),
								_ = signals.retrying.changed() => { changes.retry(); None },
								changed = changes.changed() => changed.err(),
							}
						}
					};
					if let Some(failure) = failed {
						session.state.writer.report("Signaling routes", &failure);
						signals.ready.send_replace(Some(Err(failure)));
						tokio::select! { biased;
							_ = signals.stopping.changed() => return Ok(()),
							_ = signals.retrying.changed() => changes.retry(),
						}
					}
				}
			},
		))
	}
}
fn error(error: rooms_glowcap::client::Error) -> glowcap::Error {
	loam::refusal(error.to_string())
}
