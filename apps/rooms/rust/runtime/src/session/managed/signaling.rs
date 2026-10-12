//! Exact signaling registrations retain ownership through observation failure.
use super::{Membership, Session, supervision};
use glowcap::{Argument, Result, loam};
use rooms_application::content::{
	permissions::Permission,
	session::{custody, workspace},
};
use rooms_glowcap::client::{Deadline, Tasks, directory::signaling::Route};

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
}
fn error(error: rooms_glowcap::client::Error) -> glowcap::Error {
	loam::refusal(error.to_string())
}
