//! Membership startup installs one callback, admits its effect and acquires the result.
use super::*;
impl<P: Tasks + Deadline + Clone + 'static> Worker<P> {
	pub(super) async fn run(
		&mut self,
		(mut installation, mut source): (rooms_glowcap::client::workspace::Acquisition<P>, realization::Source<P>),
		original_source: realization::Source<P>,
		target: Target,
		operation: &str,
		permit: Permit<P>,
		budget: Rc<Budget<P>>,
	) -> Result<()> {
		let workspace = source.workspace().clone();
		loop {
			match self.changes.ready().await {
				Ok(()) => break,
				Err(failure) => {
					if !self.failed(failure).await? {
						return Ok(());
					}
				}
			}
		}
		let mut conflicts = 0;
		while !*self.stopping.borrow() {
			let result = tokio::select! {
				biased;
				_ = self.stopping.changed() => return Ok(()),
				result = installation.submit() => result,
			};
			match result {
				Ok(()) => break,
				Err(rooms_glowcap::client::Error::WorkspaceConflict) => {
					conflicts += 1;
					if conflicts == 4 {
						return Err(loam::refusal("Membership installation repeatedly conflicted"));
					}
					// Only proved absence permits a new candidate. Recheck the
					// original source and selection, retaining the same callback.
					(installation, source) = original_source
						.prepare_inbox(&self.selected, self.inbox.reference())
						.await?;
				}
				Err(error) => {
					// Exact actor admission confirms installation after a lost
					// acknowledgment even if unrelated intent changed meanwhile.
					if workspace
						.check_inbox(&self.selected, self.inbox.reference())
						.await
						.is_ok()
					{
						break;
					}
					if !self.failed(super::error(error)).await? {
						return Ok(());
					}
				}
			}
		}
		if *self.stopping.borrow() {
			return Ok(());
		}
		self.installed = true;
		drop(installation);
		drop(original_source);
		let selected = self.selected.clone();
		let mut attempt = 0;
		let mut admission = operation.to_owned();
		let command = loop {
			budget.select_admission(operation, &admission);
			let Some(command) = self
				.stage(|| async {
					match &selected {
						workspace::InboxSelection::Direct { inbox, .. } => {
							source.announce_direct(&admission, *inbox).await
						}
						workspace::InboxSelection::Directory { inbox, .. } => {
							let Target::Directory { locator, .. } = &target else {
								unreachable!()
							};
							source.register(&admission, locator, *inbox).await
						}
						workspace::InboxSelection::Room { inbox, .. } => source.subscribe(&admission, *inbox).await,
					}
				})
				.await?
			else {
				return Ok(());
			};
			self.submission = Some(command.start_submission());
			let admitted = loop {
				let result = tokio::select! {
					biased;
					_ = self.stopping.changed() => return Ok(()),
					result = self.submission.as_mut().expect("owned admission observation").within(
						&self.platform,
						rooms_application::room::authority::REQUEST_TIMEOUT_MS,
					) => result,
				};
				match result {
					Some(Ok(status)) => {
						self.submission.take();
						break status;
					}
					Some(Err(failure)) => {
						self.submission.take();
						if !self.failed(error(failure)).await? {
							return Ok(());
						}
						self.submission = Some(command.start_submission());
					}
					None => {
						// Retry lends the same receiver. A deadline gives no evidence
						// that a remote admission failed or that redispatch is safe.
						if !self
							.failed(loam::refusal("Membership admission remains pending"))
							.await?
						{
							return Ok(());
						}
					}
				}
			};
			if admitted == EffectStatus::Conflict {
				// The rejected attempt installed no continuation or receipt. Prepare
				// a new operation through Source, which rechecks the exact original
				// row, callback and source before reading its new revision.
				attempt += 1;
				if attempt == 4 {
					return Err(loam::refusal("Membership admission repeatedly conflicted"));
				}
				admission = format!("{operation}:{attempt}");
				continue;
			}
			break command;
		};
		loop {
			let Some(status) = self.stage(|| async { command.status().await.map_err(error) }).await? else {
				return Ok(());
			};
			match status {
				EffectStatus::Committed => break,
				EffectStatus::Unsent => {
					// The original receipt proves no upstream dispatch. Retirement
					// drains this worker before the registry starts a fresh attempt.
					self.ready
						.send_replace(Some(Err(loam::refusal("Membership was not sent"))));
					self.recovery.recover();
					return Ok(());
				}
				EffectStatus::Pending => {
					if !self.changed().await? {
						return Ok(());
					}
				}
				_ => {
					if !self
						.failed(loam::refusal(
							"Membership requires explicit resolution of its original receipt",
						))
						.await?
					{
						return Ok(());
					}
				}
			}
		}
		if !matches!(target, Target::Direct) {
			let mut conflicts = 0;
			'acquire: loop {
				let Some(acquisition) = self
					.stage(|| async {
						match &target {
							Target::Direct => unreachable!("direct readiness returns no new authority"),
							Target::Directory { name, .. } => source.acquire_registration(&command, *name).await,
							Target::Room { seat, topic, files } => {
								let reply = command.result().await.map_err(error)?;
								let Some([data, Argument::List(_)]) = reply.as_list() else {
									return Err(loam::refusal("Membership has no committed result"));
								};
								let membership: results::Membership = serde_json::from_str(
									data.as_str()
										.ok_or_else(|| loam::refusal("Invalid membership result"))?,
								)
								.map_err(|_| loam::refusal("Invalid membership result"))?;
								source
									.acquire_membership(
										&command,
										realization::MembershipDestinations {
											seat: *seat,
											topic: membership.topic.map(|_| *topic),
											files: membership.files.map(|_| *files),
										},
									)
									.await
							}
						}
					})
					.await?
				else {
					return Ok(());
				};
				while !*self.stopping.borrow() {
					let result = tokio::select! {
						biased;
						_ = self.stopping.changed() => return Ok(()),
						result = acquisition.submit() => result,
					};
					match result {
						Ok(()) => break,
						Err(rooms_glowcap::client::Error::WorkspaceConflict) => {
							conflicts += 1;
							if conflicts == 4 {
								return Err(loam::refusal("Membership result acquisition repeatedly conflicted"));
							}
							continue 'acquire;
						}
						Err(error) => {
							if !self.failed(super::error(error)).await? {
								return Ok(());
							}
						}
					}
				}
				if *self.stopping.borrow() {
					return Ok(());
				}
				drop(acquisition);
				break;
			}
		}
		drop(command);
		drop(permit);
		self.live = true;
		if !self.apply_standing(operation, None).await? {
			return Ok(());
		}
		self.ready.send_replace(Some(Ok(())));
		loop {
			if matches!(target, Target::Direct) {
				let selection =
					serde_json::to_string(&self.selected).map_err(|_| loam::refusal("invalid direct selection"))?;
				let args = [
					self.writer.root()?.into(),
					selection.into(),
					self.inbox.reference().clone().into(),
					operation.into(),
				];
				let writer = self.writer.clone();
				let endpoint = self.workspace.reference().clone();
				if self
					.stage(|| async { writer.host.send(&endpoint, "observe-direct-connection", &args).await })
					.await?
					.is_none()
				{
					return Ok(());
				}
			}
			let retirement = self.retirement.clone();
			let changed = tokio::select! {
				biased;
				ended = async {
					match retirement {
						Some(owner) => owner.ended().await,
						None => std::future::pending().await,
					}
				} => {
					ended?;
					self.live = false;
					self.recovery.recover();
					return Ok(());
				},
				changed = self.changed() => changed?,
			};
			if !changed {
				return Ok(());
			}
			let snapshot = {
				let _inspection = self.changes.inspect().await;
				workspace.snapshot().await
			};
			match snapshot {
				Ok(snapshot) if !self.selected.matches(&snapshot.intent) => return Ok(()),
				Ok(snapshot) => {
					if !self.apply_standing(operation, Some(snapshot)).await? {
						return Ok(());
					}
				}
				// Pause or narrowing never authorizes a replacement source. The
				// inbox's shared check refuses until this exact source resumes.
				Err(_) => {}
			}
		}
	}
}
