//! Session bridge discovery and intent realization, isolated from room lifecycle work.
use super::*;
use rooms_application::bridge::Answers;

const OPERATION_LIMIT: usize = 64;

pub(super) enum Finished {
	Scope {
		id: String,
		epoch: u64,
		result: Result<Option<DocumentText>, Error>,
	},
	Submission {
		targets: Vec<(String, u64)>,
		directory: DocumentText,
		application: intent::Bridge,
		result: Result<(), Error>,
	},
}
struct Target<P: Platform> {
	id: String,
	epoch: u64,
	room: Rc<Room<P>>,
}
struct Group<P: Platform> {
	directory: DocumentText,
	application: intent::Bridge,
	answers: Result<Answers, Error>,
	targets: Vec<Target<P>>,
}

impl<P: Platform> RoomWorker<P> {
	fn wanted_bridges(&self) -> Result<HashMap<String, (DocumentText, Option<intent::Bridge>)>, Error> {
		self.commands.view().read(|state| {
			Ok(state
				.checkpoint()?
				.rooms()
				.filter_map(|room| {
					Some((
						room.id.text().as_str()?.to_owned(),
						(room.directory.text().clone(), intent::Bridge::read(room)),
					))
				})
				.collect())
		})?
	}

	/// Discovery and submissions run in owned tasks. This worker only prepares
	/// bounded inputs and publishes completions, so one remote timeout cannot
	/// delay joins, retirement notices, or shutdown.
	pub(super) async fn reconcile_bridges(&mut self) {
		let wanted = match self.wanted_bridges() {
			Ok(wanted) => wanted,
			Err(error) => {
				self.shared
					.borrow_mut()
					.issues
					.insert("room-bridge".into(), error.to_string());
				self.schedule_retry();
				return;
			}
		};
		let available = OPERATION_LIMIT.saturating_sub(self.bridges.len());
		let (discoveries, discovery_deferred): (Vec<_>, bool) = {
			let mut state = self.shared.borrow_mut();
			let mut eligible = state
				.rooms
				.values_mut()
				.filter(|live| !live.bridge_scope_known && !live.bridge_scope_pending);
			let discoveries = eligible
				.by_ref()
				.take(available)
				.map(|live| {
					live.bridge_scope_pending = true;
					(live.id.clone(), live.epoch, live.room.clone())
				})
				.collect();
			(discoveries, eligible.next().is_some())
		};
		if discovery_deferred {
			self.schedule_retry();
		}
		for (id, epoch, room) in discoveries {
			self.bridges.spawn_local(async move {
				let result = room
					.bridge_form()
					.await
					.map(|form| form.map(|form| form.scope.text().clone()))
					.map_err(Error::peer);
				Finished::Scope { id, epoch, result }
			});
		}

		let candidates: Vec<_> = {
			let mut state = self.shared.borrow_mut();
			state
				.rooms
				.values_mut()
				.filter_map(|live| {
					let (directory, desired) = wanted.get(&live.id)?;
					let Some(desired) = desired else {
						live.bridge_pending = None;
						live.applied_bridge = None;
						return None;
					};
					Some((
						live.id.clone(),
						live.epoch,
						directory.clone(),
						desired.clone(),
						live.room.clone(),
					))
				})
				.collect()
		};
		let mut groups: Vec<Group<P>> = Vec::new();
		for (id, epoch, directory, desired, room) in candidates {
			let (application, answers) = self.prepare_bridge(&directory, desired).await;
			let unchanged = self
				.shared
				.borrow()
				.rooms
				.get(&id)
				.filter(|live| live.epoch == epoch)
				.is_some_and(|live| {
					live.bridge_pending.as_ref() == Some(&application)
						|| (live.bridge_pending.is_none() && live.applied_bridge.as_ref() == Some(&application))
				});
			if unchanged {
				continue;
			}
			if let Some(group) = groups
				.iter_mut()
				.find(|group| group.directory == directory && group.application == application)
			{
				group.targets.push(Target { id, epoch, room });
				continue;
			}
			groups.push(Group {
				directory,
				application,
				answers,
				targets: vec![Target { id, epoch, room }],
			});
		}
		for group in groups {
			self.spawn_bridge(group);
		}
	}

	async fn prepare_bridge(
		&self,
		directory: &DocumentText,
		desired: intent::Bridge,
	) -> (intent::Bridge, Result<Answers, Error>) {
		let mut answers = desired.answers.clone();
		let error = if desired.secrets_given {
			match self.bridge_secrets.answers(directory, &desired.scope).await {
				Some((secrets, revision)) if revision == desired.credential_revision => secrets
					.iter()
					.try_for_each(|(key, value)| answers.insert(key.to_owned(), value.clone()))
					.err()
					.map(Error::invalid_by),
				Some(_) => Some(Error::stale(
					"saved bridge credentials do not match the committed revision",
				)),
				None => Some(Error::refused("answer this bridge again to restore its saved identity")),
			}
		} else {
			None
		};
		let application = desired;
		let answers = match error {
			Some(error) => Err(error),
			None => Ok(answers),
		};
		(application, answers)
	}

	fn spawn_bridge(&mut self, group: Group<P>) {
		if self.bridges.len() == OPERATION_LIMIT {
			self.schedule_retry();
			return;
		}
		let key = (
			group.directory.as_str().unwrap_or("").to_owned(),
			group.application.scope.lowercase().as_str().unwrap_or("").to_owned(),
		);
		let lock = {
			let mut state = self.shared.borrow_mut();
			state.bridge_locks.retain(|_, lock| lock.strong_count() > 0);
			let lock = state
				.bridge_locks
				.get(&key)
				.and_then(std::rc::Weak::upgrade)
				.unwrap_or_else(|| Rc::new(tokio::sync::Mutex::new(())));
			state.bridge_locks.insert(key, Rc::downgrade(&lock));
			for target in &group.targets {
				if let Some(live) = state
					.rooms
					.get_mut(&target.id)
					.filter(|live| live.epoch == target.epoch)
				{
					live.bridge_pending = Some(group.application.clone());
				}
			}
			lock
		};
		let commands = self.commands.clone();
		let shared = self.shared.clone();
		self.bridges.spawn_local(async move {
			let _guard = lock.lock().await;
			let current = group.targets.iter().find(|target| {
				is_current(
					&commands,
					&shared,
					&target.id,
					target.epoch,
					&group.directory,
					&group.application,
				)
			});
			let result = match (current, group.answers) {
				(None, _) => Err(Error::stale("bridge intent was superseded before dispatch")),
				(Some(_), Err(error)) => Err(error),
				(Some(target), Ok(answers)) => match group.application.action.as_str() {
					Some(action) => target
						.room
						.submit_bridge_form(action, &answers)
						.await
						.map(|_| ())
						.map_err(Error::peer),
					None => Err(Error::invalid("bridge action is not scalar text")),
				},
			};
			Finished::Submission {
				targets: group
					.targets
					.into_iter()
					.map(|target| (target.id, target.epoch))
					.collect(),
				directory: group.directory,
				application: group.application,
				result,
			}
		});
	}

	pub(super) async fn shutdown_bridges(&mut self) -> Result<(), Error> {
		self.bridges.abort_all();
		let mut result = Ok(());
		while let Some(ended) = self.bridges.join_next().await {
			if let Err(error) = ended
				&& !error.is_cancelled()
			{
				result = Error::fold(
					result,
					Err(Error::closed(format!(
						"a room bridge operation ended during shutdown: {error}"
					))),
				);
			}
		}
		result
	}

	pub(super) async fn finish_bridge(&mut self, finished: Finished) {
		match finished {
			Finished::Scope { id, epoch, result } => {
				let mut state = self.shared.borrow_mut();
				let Some(live) = state.rooms.get_mut(&id).filter(|live| live.epoch == epoch) else {
					return;
				};
				live.bridge_scope_pending = false;
				let subject = format!("room-bridge-form:{}:{}", live.directory, id);
				match result {
					Ok(scope) => {
						live.bridge_scope = scope;
						live.bridge_scope_known = true;
						state.issues.remove(&subject);
					}
					Err(error) => {
						state.issues.insert(subject, error.to_string());
						drop(state);
						self.schedule_retry();
					}
				}
			}
			Finished::Submission {
				targets,
				directory,
				application,
				result,
				..
			} => {
				let mut failed = false;
				for (id, epoch) in targets {
					if !is_current(&self.commands, &self.shared, &id, epoch, &directory, &application) {
						continue;
					}
					let subject = format!("room-bridge:{}:{}", directory.as_str().unwrap_or(""), id);
					let mut state = self.shared.borrow_mut();
					let Some(live) = state.rooms.get_mut(&id).filter(|live| live.epoch == epoch) else {
						continue;
					};
					live.bridge_pending = None;
					match &result {
						Ok(()) => {
							live.applied_bridge = Some(application.clone());
							state.issues.remove(&subject);
						}
						// A superseded intent is not this room's failure: the
						// checkpoint moved, and the next reconcile follows it.
						Err(Error::Stale(_)) => {}
						Err(error) => {
							state.issues.insert(subject, error.to_string());
							failed = true;
						}
					}
				}
				if failed {
					self.schedule_retry();
				}
			}
		}
	}
}

fn is_current<P: Platform>(
	commands: &SessionCommands,
	shared: &Rc<RefCell<LiveRooms<P>>>,
	id: &str,
	epoch: u64,
	directory: &DocumentText,
	application: &intent::Bridge,
) -> bool {
	let live = shared
		.borrow()
		.rooms
		.get(id)
		.is_some_and(|live| live.epoch == epoch && live.bridge_pending.as_ref() == Some(application));
	live && commands
		.view()
		.read(|state| {
			state
				.checkpoint()
				.ok()
				.and_then(|checkpoint| checkpoint.rooms().find(|room| room.id.text().as_str() == Some(id)))
				.is_some_and(|room| {
					room.directory.text() == directory && intent::Bridge::read(room).as_ref() == Some(application)
				})
		})
		.ok()
		.unwrap_or(false)
}
