//! The views attached to this session: who is watching, through which grant,
//! and what that grant lets them see right now. A view is retired the moment
//! its session closes, its grant is revoked, or a delivery to it fails; it
//! never outlives the authority it attached through.
use super::{
	error::Error,
	events,
	facet::{Facet, Rights},
	notice::{Notice, Report},
};
use crate::rooms::ConversationEvent;
use crate::session_service::Platform;
use glowcap::{Argument, Ref, Session};
use rooms_application::{
	grants::Access,
	session::{CHANGED, EVENT, OPERATIONS_CHANGED},
};
use std::rc::Rc;
use tokio::task::JoinHandle;

pub const MAX_ATTACHED_VIEWS: usize = 64;

/// The authority a caller reached the facet through. Views remember it so a
/// revocation retires exactly the views that authority admitted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Grantor {
	Admin,
	/// A published grant, by its ledger id.
	Grant(String),
	/// A facet minted by `facet`, by its number within this incarnation.
	Delegate(u64),
}

struct View {
	id: u64,
	session: Session,
	observer: Ref,
	grantor: Grantor,
	rights: Rights,
	/// Access transitions are delivered once even while ordinary updates are paused.
	rights_changed: bool,
	/// Names this view's event sequence; a partner treats a new source as a
	/// fresh stream rather than a gap.
	source: String,
	sequence: u64,
	close_watch: Option<JoinHandle<()>>,
}

impl Drop for View {
	fn drop(&mut self) {
		if let Some(watch) = self.close_watch.take() {
			watch.abort();
		}
	}
}

pub struct Views {
	next: u64,
	rows: Vec<View>,
	report: Report,
	snapshot_scheduled: bool,
}

/// A view whose grant is gone. It is told once more, with the reason, before
/// the peer forgets it: a link that simply goes quiet leaves its holder
/// guessing, and a snapshot naming the revocation does not.
pub struct Retired {
	pub session: Session,
	pub observer: Ref,
	pub rights: Rights,
}

/// An event with attachments, in flight to one view. The proxies live until
/// the view answers; the facet owns the wait and retires the view if the
/// answer is a refusal.
pub struct Acknowledgement {
	pub view: u64,
	pub reply: glowcap::RemotePromise,
	pub proxies: Vec<Ref>,
}

impl Views {
	pub fn new(report: Report) -> Self {
		Self {
			next: 0,
			rows: Vec::new(),
			report,
			snapshot_scheduled: false,
		}
	}
	pub fn attach(&mut self, session: Session, observer: Ref, grantor: Grantor, rights: Rights) -> Result<u64, Error> {
		if self.rows.len() >= MAX_ATTACHED_VIEWS {
			return Err(Error::refused("this Rooms session has reached its attached-view limit"));
		}
		let id = self.next;
		self.next += 1;
		self.rows.push(View {
			id,
			session,
			observer,
			grantor,
			rights,
			rights_changed: true,
			source: format!("watch-{id}"),
			sequence: 0,
			close_watch: None,
		});
		Ok(id)
	}
	/// The task that retires the view when its session closes. Held so a
	/// view retired another way does not leave a watcher behind.
	pub fn watch_close(&mut self, id: u64, watch: JoinHandle<()>) {
		if let Some(view) = self.rows.iter_mut().find(|view| view.id == id) {
			view.close_watch = Some(watch);
		} else {
			watch.abort();
		}
	}
	pub fn remove(&mut self, id: u64) {
		self.rows.retain(|view| view.id != id);
	}
	pub fn clear(&mut self) {
		self.rows.clear();
	}
	/// The grant ledger is gone: nothing that attached through a grant may
	/// keep watching.
	pub fn retire_granted(&mut self) {
		self.rows.retain(|view| !matches!(view.grantor, Grantor::Grant(_)));
	}
	pub fn retire_grantor(&mut self, grantor: &Grantor) {
		self.rows.retain(|view| view.grantor != *grantor);
	}
	/// Re-read every granted view's rights from the ledger. A grant that is
	/// gone retires its views; a narrowed one narrows what its views receive.
	pub fn retier(&mut self, lookup: impl Fn(&str) -> Option<Rights>) -> Vec<Retired> {
		let mut retired = Vec::new();
		self.rows.retain_mut(|view| {
			let Grantor::Grant(id) = &view.grantor else {
				return true;
			};
			match lookup(id) {
				Some(rights) => {
					view.rights_changed |= view.rights != rights;
					view.rights = rights;
					true
				}
				None => {
					retired.push(Retired {
						session: view.session.borrowed(),
						observer: view.observer.clone(),
						rights: view.rights.clone(),
					});
					false
				}
			}
		});
		retired
	}
	pub fn operations_changed(&mut self, scope: &str) {
		let args = [Argument::from(scope)];
		let report = self.report.clone();
		self.rows.retain(|view| {
			if !view.rights.is_admin() {
				return true;
			}
			deliver(view, OPERATIONS_CHANGED, &args)
				.map_err(|cause| report(Notice::ViewRetired { cause }))
				.is_ok()
		});
	}
	pub fn history_changed(&mut self, change: &rooms_application::archive::change::Change) {
		use rooms_application::archive::{change::Change, ConversationKind};
		let args = match change {
			Change::Conversation {
				kind,
				directory,
				conversation,
			} => {
				match (directory.as_str(), conversation.as_str()) {
					(Some(directory), Some(conversation)) => vec![
						match kind {
							ConversationKind::Room => "room",
							ConversationKind::Direct => "direct",
						}
						.into(),
						directory.into(),
						conversation.into(),
					],
					// Wire strings are scalar text. Broaden the invalidation rather
					// than changing a non-scalar archive identity during encoding.
					_ => Vec::new(),
				}
			}
			Change::All => Vec::new(),
		};
		let report = self.report.clone();
		self.rows.retain(|view| {
			if view.rights.access == Access::None || !view.rights.history {
				return true;
			}
			deliver(view, rooms_application::session::HISTORY_CHANGED, &args)
				.map_err(|cause| report(Notice::ViewRetired { cause }))
				.is_ok()
		});
	}
	/// Deliver to every view but the one attached over `except`, so a view's
	/// own typing is not echoed back to it. An event carrying attachments is
	/// sent rather than told: its proxies are owned roots that must outlive
	/// the drain that exports them, so they ride the returned acknowledgement
	/// and drop only once the view has answered.
	pub fn event_except(
		&mut self,
		event: &ConversationEvent,
		except: Option<&Session>,
		answers: &super::answer::Answers,
	) -> Vec<Acknowledgement> {
		let report = self.report.clone();
		let mut pending = Vec::new();
		self.rows.retain_mut(|view| {
			if view.rights.access == Access::None || except.is_some_and(|caller| caller.same_session(&view.session)) {
				return true;
			}
			view.sequence = view.sequence.saturating_add(1);
			let outcome = events::encode(
				&view.session,
				&view.source,
				view.sequence,
				&view.rights,
				event,
				&report,
				answers,
			)
			.and_then(|(args, proxies)| {
				if proxies.is_empty() {
					return deliver(view, EVENT, &args);
				}
				pending.push(Acknowledgement {
					view: view.id,
					reply: view.session.send(&view.observer, EVENT, &args),
					proxies,
				});
				Ok(())
			});
			outcome.map_err(|cause| report(Notice::ViewRetired { cause })).is_ok()
		});
		pending
	}
	/// Snapshots are delivered once per tick, however many owners changed in
	/// it, and encoded once per distinct rights rather than once per view.
	pub fn schedule_snapshots<P: Platform>(facet: &Facet<P>) {
		{
			let mut views = facet.views();
			if views.rows.is_empty() || views.snapshot_scheduled {
				return;
			}
			views.snapshot_scheduled = true;
		}
		let weak = Rc::downgrade(&facet.0);
		if let Err(cause) = facet.0.answers.spawn(async move {
			tokio::task::yield_now().await;
			if let Some(inner) = weak.upgrade() {
				flush_snapshots(&Facet(inner));
			}
		}) {
			let mut views = facet.views();
			views.snapshot_scheduled = false;
			views.clear();
			(views.report)(Notice::ViewRetired { cause });
		}
	}
}

fn deliver(view: &View, verb: &str, args: &[Argument]) -> Result<(), Error> {
	Ok(view.session.tell(&view.observer, verb, args)?)
}

pub(super) fn flush_snapshots<P: Platform>(facet: &Facet<P>) {
	struct Target {
		id: u64,
		rights: Rights,
	}
	let targets: Vec<Target> = {
		let mut views = facet.views();
		views.snapshot_scheduled = false;
		views
			.rows
			.iter()
			.filter(|view| view.rights.access != Access::None || view.rights_changed)
			.map(|view| Target {
				id: view.id,
				rights: view.rights.clone(),
			})
			.collect()
	};
	// One encoding per distinct rights; a rights whose snapshot cannot be
	// encoded retires every view holding it under one notice.
	let mut encoded: Vec<(Rights, Option<Vec<Argument>>)> = Vec::new();
	let mut retired = Vec::new();
	for target in targets {
		let position = match encoded.iter().position(|(rights, _)| *rights == target.rights) {
			Some(position) => position,
			None => {
				let args = match facet.encode_snapshot(&target.rights, &[]) {
					Ok(args) => Some(args),
					Err(cause) => {
						(facet.views().report)(Notice::ViewRetired { cause });
						None
					}
				};
				encoded.push((target.rights.clone(), args));
				encoded.len() - 1
			}
		};
		let Some(args) = &encoded[position].1 else {
			retired.push((target.id, None));
			continue;
		};
		let mut views = facet.views();
		let Some(view) = views.rows.iter_mut().find(|view| view.id == target.id) else {
			continue;
		};
		view.rights_changed = false;
		if let Err(cause) = deliver(view, CHANGED, args) {
			retired.push((target.id, Some(cause)));
		}
	}
	let mut views = facet.views();
	for (id, cause) in retired {
		views.remove(id);
		if let Some(cause) = cause {
			(views.report)(Notice::ViewRetired { cause });
		}
	}
}
