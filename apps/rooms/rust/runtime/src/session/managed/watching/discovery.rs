//! One directory discovery worker per exact saved selection. This registry
//! owns views only. The session retains each worker and upstream cancellation.
use super::super::{
	DirectoryWatch, MembershipEvent, MembershipReceiver, MembershipReport, MembershipTarget, Session,
	coordination::stands,
};
use glowcap::Result;
use rooms_application::content::session::workspace::{self, Intent};
use rooms_glowcap::client::{Deadline, Tasks};
use std::{cell::RefCell, collections::BTreeMap, rc::Rc};

enum Entry<P: Tasks> {
	/// Starting the watch refused for a reason that clears only with a change:
	/// the row, the session's transports, or an explicit retry. Reconciliation
	/// reports the refusal standing and never dials the address again on a
	/// recovery wake.
	Failed {
		selected: workspace::DiscoverySelection,
		failure: glowcap::Error,
	},
	Watching(Watching<P>),
}
struct Watching<P: Tasks> {
	selected: workspace::DiscoverySelection,
	watch: DirectoryWatch<P>,
	receive: Rc<RefCell<MembershipReceiver>>,
	snapshot_delivered: bool,
	failure: Option<glowcap::Error>,
	snapshot: Option<rooms_application::directory::Snapshot>,
}
pub(super) struct Discoveries<P: Tasks>(BTreeMap<String, Entry<P>>);
impl<P: Tasks> Default for Discoveries<P> {
	fn default() -> Self {
		Self(BTreeMap::new())
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Discoveries<P> {
	pub(super) fn append_status(&self, report: &mut MembershipReport) {
		for (id, entry) in &self.0 {
			let failure = match entry {
				Entry::Failed { failure, .. } => failure.clone(),
				Entry::Watching(watching) => match watching.watch.status() {
					Some(Err(error)) => error,
					_ if !watching.watch.is_active() => glowcap::loam::refusal("Directory discovery connection ended"),
					Some(Ok(())) if watching.snapshot_delivered => {
						report.ready += 1;
						continue;
					}
					_ => continue,
				},
			};
			report.failures.push((MembershipTarget::Discovery(id.clone()), failure));
		}
	}
	/// Only an explicit outer retry reopens a standing startup refusal. The
	/// next reconciliation finds the slot vacant and dials the address again.
	pub(super) fn retry_failed(&mut self) {
		self.0.retain(|_, entry| matches!(entry, Entry::Watching(_)));
	}
	pub async fn reconcile(
		&mut self,
		session: &Session<P>,
		intent: &Intent,
		mut receive: impl FnMut(&MembershipTarget) -> MembershipReceiver,
	) -> MembershipReport {
		let mut report = MembershipReport::default();
		let desired: BTreeMap<_, _> = intent
			.directories
			.as_slice()
			.iter()
			.filter_map(|row| {
				Some((
					row.id.text().as_str()?,
					(row, workspace::DiscoverySelection::directory(row)?),
				))
			})
			.collect();
		loop {
			let obsolete = self
				.0
				.iter()
				.find(|(id, entry)| {
					!report
						.failures
						.iter()
						.any(|(target, _)| target == &MembershipTarget::Discovery((*id).clone()))
						&& match entry {
							Entry::Failed { selected, .. } => {
								desired.get(id.as_str()).is_none_or(|(_, wanted)| wanted != selected)
							}
							Entry::Watching(watching) => {
								!watching.watch.is_active()
									|| desired
										.get(id.as_str())
										.is_none_or(|(_, wanted)| wanted != &watching.selected)
							}
						}
				})
				.map(|(id, _)| id.clone());
			let Some(id) = obsolete else { break };
			match self.0.get_mut(&id) {
				None => report.failures.push((
					MembershipTarget::Discovery(id),
					glowcap::loam::refusal("directory discovery observer is not retained"),
				)),
				Some(Entry::Failed { .. }) => {
					self.0.remove(&id);
				}
				Some(Entry::Watching(watching)) => match watching.watch.close().await {
					Ok(()) => {
						self.0.remove(&id);
					}
					Err(error) => report.failures.push((MembershipTarget::Discovery(id), error)),
				},
			}
		}
		for (id, (row, selected)) in desired {
			let target = MembershipTarget::Discovery(id.into());
			if report.failures.iter().any(|(failed, _)| failed == &target) {
				continue;
			}
			if let std::collections::btree_map::Entry::Vacant(slot) = self.0.entry(id.into()) {
				let receiver = Rc::new(RefCell::new(receive(&target)));
				let notifications = receiver.clone();
				match session
					.watch_directory(row, move |event, origin| {
						notifications.borrow_mut()(MembershipEvent::DirectoryChanged { event, origin }).map(|_| ())
					})
					.await
				{
					Ok(watch) => {
						slot.insert(Entry::Watching(Watching {
							selected,
							watch,
							receive: receiver,
							snapshot_delivered: false,
							failure: None,
							snapshot: None,
						}));
					}
					Err(error) => {
						if stands(&error) {
							slot.insert(Entry::Failed {
								selected,
								failure: error.clone(),
							});
						}
						report.failures.push((target, error));
						continue;
					}
				}
			}
			let entry = match self.0.get_mut(id) {
				Some(Entry::Watching(watching)) => watching,
				Some(Entry::Failed { failure, .. }) => {
					report.failures.push((target, failure.clone()));
					continue;
				}
				None => {
					report.failures.push((
						target,
						glowcap::loam::refusal("directory discovery observer is not retained"),
					));
					continue;
				}
			};
			if let Some(failure) = &entry.failure {
				let closed = entry.watch.close().await;
				let failure = failure.clone().with_cleanup(closed.clone());
				if closed.is_ok() {
					self.0.remove(id);
				}
				report.failures.push((target, failure));
				continue;
			}
			if !entry.watch.is_active() {
				// Retirement is permanent for this exact selection. A later
				// reconciliation cannot silently recreate a revoked observer.
				report.failures.push((
					target,
					glowcap::loam::refusal("directory discovery selection has retired"),
				));
				continue;
			}
			if entry.snapshot_delivered {
				if let Some(Err(error)) = entry.watch.status() {
					entry.watch.retry();
					report.failures.push((target, error));
				} else {
					report.ready += 1;
				}
				continue;
			}
			let delivered = async {
				if entry.snapshot.is_none() {
					entry.snapshot = Some(entry.watch.snapshot().await?);
				}
				// Snapshot reception may wait while the row or grant changes.
				// Reauthorize through its original endpoint immediately before
				// synchronous downstream delivery and notification activation.
				let source = session.directory_source(row).await?;
				source
					.workspace()
					.check_discovery(&entry.selected)
					.await
					.map_err(|error| glowcap::loam::refusal(error.to_string()))?;
				(entry.receive.borrow_mut())(MembershipEvent::DirectorySnapshot {
					snapshot: entry
						.snapshot
						.as_ref()
						.ok_or_else(|| glowcap::loam::refusal("directory snapshot is not held"))?,
					origin: entry.watch.origin(),
				})
				.map_err(glowcap::loam::refusal)?;
				entry.watch.accept_snapshot();
				entry.snapshot.take();
				Ok::<_, glowcap::Error>(())
			}
			.await;
			match delivered {
				Ok(()) => {
					entry.snapshot_delivered = true;
					report.ready += 1;
				}
				Err(failure) => {
					entry.failure = Some(failure.clone());
					let closed = entry.watch.close().await;
					if closed.is_ok() {
						self.0.remove(id);
					}
					report.failures.push((target, failure.with_cleanup(closed)));
				}
			}
		}
		report
	}
	pub async fn close(&mut self) -> Result<()> {
		let mut result = Ok(());
		for entry in self.0.values_mut() {
			let Entry::Watching(watching) = entry else { continue };
			if let Err(error) = watching.watch.close().await {
				result = match result {
					Ok(()) => Err(error),
					Err(first) => Err(first.with_cleanup(Err(error))),
				};
			}
		}
		self.0
			.retain(|_, entry| matches!(entry, Entry::Watching(watching) if watching.watch.is_active()));
		result
	}
}
