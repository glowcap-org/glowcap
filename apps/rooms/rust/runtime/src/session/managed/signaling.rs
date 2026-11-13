//! Exact signaling registrations retain ownership through observation failure.
use crate::Error;
type Result<T> = core::result::Result<T, Error>;
use super::{Membership, Session, supervision};
use glowcap::{Argument, loam};
use rooms_application::content::{
	permissions::Permission,
	session::{custody, workspace},
};
use rooms_glowcap::client::{Deadline, Tasks, directory::signaling::Route};
use std::collections::BTreeMap;

/// How long the directory's answer about a registration stands. The directory
/// can withdraw a name while its holder stays connected, and it tells the
/// holder nothing. A session still in use asks again at its first workspace
/// change after this long, which is how it hears of a withdrawn name. An idle
/// session asks nothing.
const DIRECTORY_ANSWER_STANDS_MS: u64 = 60_000;
/// `answered` is when the directory last answered, or `None` when a retry or a
/// failure put its answer in doubt.
fn directory_answer_stands(answered: Option<u64>, now: u64) -> bool {
	answered.is_some_and(|at| now.saturating_sub(at) < DIRECTORY_ANSWER_STANDS_MS)
}

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
		.map_err(Error::from)?
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
			.ok_or_else(|| Error::stale("signaling has no exact registered name and source"))?;
		let source = self.directory_source(row).await?;
		let mut route = source.workspace().signaling(&selected).await.map_err(Error::from)?;
		let directory = self
			.restore_custody(&[custody::Coordinate {
				role: custody::Role::DirectoryAccess,
				key: row.access.retag(),
			}])
			.await?
			.remove(0);
		route.retain_introducer(&directory).map_err(Error::from)?;
		route.check().await.map_err(Error::from)?;
		Ok(route)
	}
	pub async fn signaling_registration(&self, row: &workspace::Directory) -> Result<SignalingRegistration<P>> {
		let _permit = supervision::Permit::reserve(&self.state.signaling_observers)?;
		let selected = workspace::SignalingSelection::directory(row)
			.ok_or_else(|| Error::stale("signaling has no exact registered name and source"))?;
		let id = format!(
			"signaling-{}",
			row.id
				.text()
				.as_str()
				.ok_or_else(|| Error::invalid("invalid signaling directory"))?
		);
		if self.state.closing.get() {
			return Err(Error::closed("Session is closing"));
		}
		if self.state.signaling_observers.contains(&id) {
			return Err(Error::busy("signaling is already supervised"));
		}
		let source = self.directory_source(row).await?;
		let route = self.signaling_route(row).await?;
		// Concurrent startups may have installed this identity while we waited.
		if self.state.closing.get() {
			return Err(Error::closed("Session is closing"));
		}
		if self.state.signaling_observers.contains(&id) {
			return Err(Error::busy("signaling is already supervised"));
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
				// `signaling_route` asked the directory once. A workspace change can
				// replace the selection or pause its source, and both are read
				// here from this session. It cannot change what the directory
				// holds, so a change alone is no reason to ask the directory. A
				// retry and a failed pass ask at once.
				let mut directory_answered = Some(platform.monotonic_millis());
				loop {
					if *signals.stopping.borrow_and_update() {
						return Ok(());
					}
					let ask_directory = !directory_answer_stands(directory_answered, platform.monotonic_millis());
					let checked = tokio::select! { biased;
						_ = signals.stopping.changed() => return Ok(()),
						checked = platform.within(20_000, async {
							changes.ready().await?;
							let encoded = serde_json::to_string(&selected)
								.map_err(|_| Error::invalid("invalid signaling selection"))?;
							match writer.idempotent("signaling-selected", &[encoded.into()]).await? {
								Argument::Boolean(false) => return Ok(false),
								Argument::Boolean(true) => {},
								_ => return Err(Error::invalid("invalid signaling selection acknowledgment")),
							}
							let description = writer.idempotent_through(workspace.reference(), "describe-access", &[]).await?;
							let active = match loam::UseDescription::read(&description)? {
								loam::UseDescription::Active(source) => source.effective.permissions()
									.any(|permission| permission == Permission::InteractWorkspace.key()),
								_ => false,
							};
							if !active { return Ok(false); }
							if ask_directory {
								checking.check().await.map_err(Error::from)?;
							}
							Ok(true)
						}) => checked.unwrap_or_else(|| Err(Error::uncertain("signaling source check is still unresolved"))),
					};
					let failed = match checked {
						// Only affirmative source/selection evidence releases this owner.
						Ok(false) => return Ok(()),
						Err(failure) => Some(failure),
						Ok(true) => {
							if ask_directory {
								directory_answered = Some(platform.monotonic_millis());
							}
							signals.ready.send_replace(Some(Ok(())));
							tokio::select! { biased;
								_ = signals.stopping.changed() => return Ok(()),
								_ = signals.retrying.changed() => {
									directory_answered = None;
									changes.retry();
									continue;
								},
								changed = changes.changed() => changed.err(),
							}
						}
					};
					if let Some(failure) = failed {
						directory_answered = None;
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
		if self.state.closing.get() {
			return Err(Error::closed("Session is closing"));
		}
		if self.state.signaling_observers.contains(&id) {
			return Err(Error::busy("signaling routes are already followed"));
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
						let intent = workspace.snapshot().await.map_err(Error::from)?.intent;
						let mut selected = BTreeMap::new();
						for row in intent.directories.as_slice() {
							if let Some(selection) = workspace::SignalingSelection::directory(row) {
								let id = row
									.id
									.text()
									.as_str()
									.ok_or_else(|| Error::invalid("invalid directory"))?;
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
						Ok::<(), Error>(())
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

#[cfg(test)]
mod tests {
	use super::{DIRECTORY_ANSWER_STANDS_MS, directory_answer_stands};

	#[test]
	fn the_directory_is_asked_again_once_its_answer_is_old_or_in_doubt() {
		assert!(directory_answer_stands(Some(1_000), 1_000));
		assert!(directory_answer_stands(
			Some(1_000),
			1_000 + DIRECTORY_ANSWER_STANDS_MS - 1
		));
		assert!(!directory_answer_stands(
			Some(1_000),
			1_000 + DIRECTORY_ANSWER_STANDS_MS
		));
		assert!(
			!directory_answer_stands(None, 1_000),
			"a retry or a failure asks at once"
		);
		assert!(
			directory_answer_stands(Some(1_000), 0),
			"a clock behind the answer does not ask"
		);
	}
}
