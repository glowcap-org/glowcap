//! Answering a CapTP call from outside its turn. Every verb that must wait
//! on disk, a delivery, or bytes still arriving settles its promise through
//! here, so the defer, the settle, and the report of an undeliverable answer
//! live once. The loop owns the task, through the work queue.
use super::{
	notice::Notice,
	state::{State, Work},
};
use glowcap::{Argument, current_session};
use std::future::Future;

/// The work queue is full: the caller retries rather than the server
/// growing a queue on its word.
pub(super) fn busy() -> String {
	"the server is busy; try again".into()
}

/// Defer the current turn and settle it with `work`'s outcome. An answer
/// whose caller has since closed its session has nobody to reach and is
/// dropped. One that cannot be delivered to a caller still there is reported.
pub(super) fn later<F>(state: &State, verb: &'static str, work: F) -> Result<Argument, String>
where
	F: Future<Output = Result<Argument, String>> + 'static,
{
	let seat = state.reserve().ok_or_else(busy)?;
	let session = current_session()
		.map_err(|e| e.to_string())?
		.ok_or("a deferred answer is reachable only over a session")?
		.borrowed();
	let mut deferred = session.host().defer_turn().map_err(|e| e.to_string())?;
	let report = state.reporter();
	seat.send(Work::Task(Box::pin(async move {
		let delivery = match work.await {
			Ok(value) if carries_capability(&value) => deferred.fulfill_value(&value),
			Ok(value) => deferred.fulfill(&value),
			Err(reason) => deferred.break_with(&reason),
		};
		if let Err(cause) = delivery
			&& session.is_open()
		{
			report(Notice::AnswerUndeliverable { verb, cause });
		}
	})));
	Ok(Argument::Void)
}

fn carries_capability(value: &Argument) -> bool {
	use rooms_application::room::ArgumentView;
	rooms_glowcap::Value(value).contains_capability()
}
