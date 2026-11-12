//! One deferred introduction owns its exact registrations until an offer arrives.
//! Readiness wakes that operation alone. Only its guard releases the waiting slot.
//! The slots bound the tasks that answer held introductions, so those tasks
//! run here and take no seat in the server's work queue.
use super::{behavior::Shared, state::Policy};
use glowcap::{Argument, Ref};
use rooms_application::{
	directory::{introduction, registration::Id},
	failure::FailureCode,
	server::directory::{InboxOffered, Introduction, Tell},
};
use std::{cell::RefCell, collections::BTreeMap, rc::Rc, time::Duration};
use tokio::{sync::oneshot, task::JoinSet, time::Instant};

#[cfg(test)]
mod tests;

// Admission rates are configurable. This bound still leaves other callers
// their share of `introduction::MAX_OUTSTANDING`.
pub(super) const MAX_PER_CALLER: usize = 32;

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Key {
	caller: u64,
	target: Id,
	opening: String,
}
struct Entry {
	source: Id,
	target_connection: u64,
	ready: Option<oneshot::Sender<Result<(), String>>>,
}
type Entries = Rc<RefCell<BTreeMap<Key, Entry>>>;
#[derive(Default)]
pub(super) struct Pending {
	entries: Entries,
	/// The answer of each held introduction. Every task owns one `Waiting`
	/// and ends within its deadline, so `park` bounds how many run. The
	/// serving loop joins them.
	pub tasks: JoinSet<()>,
}

impl Pending {
	/// Run a held introduction's answer for as long as its `Waiting` lasts.
	pub fn hold(&mut self, answer: impl Future<Output = ()> + 'static) {
		self.tasks.spawn_local(answer);
	}
	/// An introduction that answers at once still refuses while the same one
	/// is held, so one opening has one answer.
	pub fn unparked(&self, caller: u64, target: &Id, opening: &str) -> Result<(), String> {
		let key = Key {
			caller,
			target: target.clone(),
			opening: opening.into(),
		};
		if self.entries.borrow().contains_key(&key) {
			return Err(PENDING.into());
		}
		Ok(())
	}
	pub fn park(
		&self,
		policy: &Policy,
		caller: u64,
		target: Id,
		opening: &str,
		target_connection: u64,
	) -> Result<Waiting, String> {
		let source = policy
			.registered_nick(caller)
			.ok_or_else(caller_ended)
			.and_then(|nick| policy.member_registration(nick).map_err(|r| r.reason()))?;
		let mut entries = self.entries.borrow_mut();
		let key = Key {
			caller,
			target,
			opening: opening.into(),
		};
		if entries.contains_key(&key) {
			return Err(PENDING.into());
		}
		if entries.len() >= introduction::MAX_OUTSTANDING
			|| entries.keys().filter(|key| key.caller == caller).count() >= MAX_PER_CALLER
		{
			return Err(FailureCode::AdmissionBusy.line(introduction::Error::Full));
		}
		let (ready, receive) = oneshot::channel();
		entries.insert(
			key.clone(),
			Entry {
				source: source.clone(),
				target_connection,
				ready: Some(ready),
			},
		);
		Ok(Waiting {
			owner: self.entries.clone(),
			key,
			source,
			receive,
			deadline: Instant::now() + Duration::from_millis(introduction::WAIT_MS),
		})
	}
	pub fn offered(&self, offered: &InboxOffered<u64>) {
		let key = Key {
			caller: offered.caller,
			target: offered.target.clone(),
			opening: offered.opening.clone(),
		};
		if let Some(entry) = self.entries.borrow_mut().get_mut(&key) {
			entry.signal(Ok(()));
		}
	}
	/// Membership changes are rare and the scan is bounded by MAX_OUTSTANDING.
	/// Ordinary room messages do not inspect introduction waiters.
	pub fn revalidate(&self, policy: &Policy) {
		for (key, entry) in self.entries.borrow_mut().iter_mut() {
			if policy.registration_connection(&entry.source).ok() != Some(key.caller) {
				entry.signal(Err(caller_ended()));
			} else if policy.registration_connection(&key.target).ok() != Some(entry.target_connection) {
				entry.signal(Err(ended()));
			}
		}
	}
	pub fn closed(&self, connection: u64) {
		for (key, entry) in self.entries.borrow_mut().iter_mut() {
			if key.caller == connection {
				entry.signal(Err(caller_ended()));
			} else if entry.target_connection == connection {
				entry.signal(Err(ended()));
			}
		}
	}
}
impl Entry {
	fn signal(&mut self, outcome: Result<(), String>) {
		if let Some(ready) = self.ready.take() {
			// tolerant: a cancelled operation has no wakeup observer.
			let _ = ready.send(outcome);
		}
	}
}
pub(super) struct Waiting {
	owner: Entries,
	key: Key,
	source: Id,
	receive: oneshot::Receiver<Result<(), String>>,
	/// When the caller's wait ends, counted from when the introduction was held.
	deadline: Instant,
}
impl Waiting {
	/// The target's offer, the end of either registration, or the deadline,
	/// whichever comes first. `notified` is the outcome of telling the target.
	async fn offer(&mut self, notified: impl Future<Output = Result<(), String>>) -> Result<(), String> {
		let deadline = self.deadline;
		let offered = async {
			tokio::select! {
				// An offer proves the target handled the notification. Dropping
				// `notified` releases only our result observation; it does not undo
				// delivery or close the shared session. No capability is expected
				// in its reply.
				biased;
				ready = &mut self.receive => ready.map_err(|_| ended())?,
				sent = notified => {
					sent?;
					(&mut self.receive).await.map_err(|_| ended())?
				}
			}
		};
		tokio::time::timeout_at(deadline, offered)
			.await
			.map_err(|_| timed_out())?
	}
}
impl Drop for Waiting {
	fn drop(&mut self) {
		self.owner.borrow_mut().remove(&self.key);
	}
}
const PENDING: &str = "this exact introduction is already pending";
/// The member the caller asked for left before its direct inbox arrived.
fn ended() -> String {
	FailureCode::PeerOffline.line("the member's registration ended before its direct inbox arrived")
}
fn timed_out() -> String {
	FailureCode::IntroductionTimedOut.line("the member did not supply its direct inbox before the deadline")
}
/// The caller gave up its own name while its introduction was held.
fn caller_ended() -> String {
	FailureCode::NotRegistered.line("the caller's registration ended before the direct inbox arrived")
}

pub(super) async fn resolve(
	state: Shared,
	mut waiting: Waiting,
	target: Tell<u64, Ref>,
	nick: String,
) -> Result<Argument, String> {
	let session = state
		.borrow()
		.session(target.connection)
		.map(glowcap::Session::borrowed)
		.ok_or_else(ended)?;
	let args = super::state::notice_args(&target.notice);
	let delivery = session.send(&target.inbox, rooms_application::room::inbox::NOTIFY, &args);
	waiting
		.offer(async {
			delivery.await.map(|_| ()).map_err(|cause| {
				state.borrow().report(super::notice::Notice::DeliveryFailed {
					what: "inbox request",
					cause,
				});
				FailureCode::MemberUnreachable.line("the inbox request could not be delivered")
			})
		})
		.await?;
	let mut state = state.borrow_mut();
	if state.policy.registration_connection(&waiting.source).ok() != Some(waiting.key.caller) {
		return Err(caller_ended());
	}
	match state
		.policy
		.introduce(
			waiting.key.caller,
			&nick,
			waiting.key.target.as_str(),
			&waiting.key.opening,
		)
		.map_err(|r| r.reason())?
	{
		Introduction::Inbox(inbox) => Ok(Argument::Reference(inbox)),
		Introduction::Pending(_) => Err(FailureCode::IntroductionRefused.line("the offered inbox is no longer held")),
	}
}
