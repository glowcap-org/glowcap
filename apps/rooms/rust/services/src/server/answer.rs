//! Answering a CapTP call from outside its turn. Every verb that must wait
//! on disk, a delivery, or bytes still arriving settles its promise through
//! here, so the defer, the settle, and the report of an undeliverable answer
//! live once. The loop owns the task, through the work queue or through the
//! owner that bounds its kind.
use super::{
	notice::Notice,
	state::{State, Work},
};
use glowcap::{Argument, current_session};
use rooms_application::{failure::FailureCode, server::Refusal};
use std::future::Future;

/// A bounded queue is full: the caller retries rather than the server
/// growing a queue on its word. The code tells the other side that the work
/// it asked for never started, so every caller refuses with this before it
/// starts any.
pub(super) fn busy(queue: &str) -> Refusal {
	Refusal::coded(FailureCode::AdmissionBusy, format!("the {queue} queue is full"))
}
/// The serving loop's work queue is full.
pub(super) fn work_busy() -> String {
	busy("server work").reason()
}

/// The refusal a caller reads when the server another directory named
/// answered its call with a break: the catalog line, code first, when the
/// break names one, so the caller's page still reads which failure it was.
pub(super) fn relayed_refusal(error: glowcap::Error) -> String {
	rooms_runtime::Error::from(error).into_refusal()
}

/// Defer the current turn and settle it with `work`'s outcome, in the seat
/// `State::reserve` gave the caller.
pub(super) fn later<F>(
	state: &State,
	seat: tokio::sync::mpsc::OwnedPermit<Work>,
	verb: &'static str,
	work: F,
) -> Result<Argument, String>
where
	F: Future<Output = Result<Argument, String>> + 'static,
{
	seat.send(Work::Task(Box::pin(deferred(state, verb, work)?)));
	Ok(Argument::Void)
}

/// Defer the current turn. The task this returns settles it with `work`'s
/// outcome, and whoever bounds that kind of work runs it. An answer whose
/// caller has since closed its session has nobody to reach and is dropped.
/// One that cannot be delivered to a caller still there is reported.
pub(super) fn deferred<F>(
	state: &State,
	verb: &'static str,
	work: F,
) -> Result<impl Future<Output = ()> + 'static, String>
where
	F: Future<Output = Result<Argument, String>> + 'static,
{
	let session = current_session()
		.map_err(|e| e.to_string())?
		.ok_or("a deferred answer is reachable only over a session")?
		.borrowed();
	let mut deferred = session.host().defer_turn().map_err(|e| e.to_string())?;
	let report = state.reporter();
	Ok(async move {
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
	})
}

fn carries_capability(value: &Argument) -> bool {
	use rooms_application::room::ArgumentView;
	rooms_glowcap::Value(value).contains_capability()
}

#[cfg(test)]
mod tests {
	use rooms_application::failure::{Failure, FailureCode};

	/// A full queue is the server at capacity, so it reads as the catalog's
	/// busy code and as a refusal that started nothing.
	#[test]
	fn a_full_queue_refuses_with_the_busy_code() {
		for reason in [super::work_busy(), super::busy("history writer").reason()] {
			let failure = Failure::parse(&reason).expect("a coded refusal");
			assert_eq!(failure.code, FailureCode::AdmissionBusy);
			assert!(failure.refused_before_dispatch());
		}
	}
}
