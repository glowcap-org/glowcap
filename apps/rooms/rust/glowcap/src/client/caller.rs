//! One route for the typed requests of a held capability. A `Remote` caller
//! sends over the client's own session. A `Hosted` caller sends through the
//! application's Host, either to a capability served in this process or, when
//! `attached`, over the Host's connection to the session that serves it.
use super::{Argument, Client, Deadline, Error, Future, Ref};
use glowcap::Host;
use rooms_application::{
	failure::FailureCode,
	room::authority::{CALL_BOUND_MS, REQUEST_TIMEOUT_MS},
};

#[derive(Clone)]
pub(crate) enum Caller<D> {
	Remote(Client<D>),
	Hosted {
		host: Host,
		platform: D,
		/// The session this caller is attached to, through a connection that
		/// can break.
		attached: Option<Attached>,
	},
}
/// A capability another process serves, and the request it answers from its
/// own state. A call that misses its deadline may be waiting on another peer
/// the session asked, so the capability is asked `probe` once more. Only one
/// that misses that too has lost the link.
#[derive(Clone)]
pub(crate) struct Attached {
	pub(crate) session: Ref,
	pub(crate) probe: &'static str,
}
impl<D> Caller<D> {
	/// Calls a capability this process serves. No connection can break under it.
	pub(crate) fn hosted(host: Host, platform: D) -> Self {
		Self::Hosted {
			host,
			platform,
			attached: None,
		}
	}
	/// Calls a capability another process serves, so a call that fails with
	/// the connection is named as a lost link.
	pub(crate) fn attached(host: Host, platform: D, attached: Attached) -> Self {
		Self::Hosted {
			host,
			platform,
			attached: Some(attached),
		}
	}
}
impl<D: Deadline> Caller<D> {
	pub fn host(&self) -> Host {
		match self {
			Self::Remote(client) => client.session().host(),
			Self::Hosted { host, .. } => host.clone(),
		}
	}
	pub fn platform(&self) -> &D {
		match self {
			Self::Remote(client) => client.platform(),
			Self::Hosted { platform, .. } => platform,
		}
	}
	pub fn session(&self) -> Option<&std::rc::Rc<super::Session>> {
		match self {
			Self::Remote(client) => Some(&client.session),
			Self::Hosted { .. } => None,
		}
	}
	pub fn tell(&self, source: &Ref, verb: &str, args: &[Argument]) -> Result<(), Error> {
		match self {
			Self::Remote(client) => client.session().tell(source, verb, args),
			Self::Hosted { host, .. } => host.tell(source, verb, args),
		}
		.map_err(Error::from)
	}
	/// Files may come from a third peer or a local managed facade. The Host
	/// routes the actual capability. Retaining the remote client still keeps
	/// its delivering connection alive without guessing a blob's exporter.
	pub fn call_reference(
		&self,
		source: &Ref,
		verb: &'static str,
		args: &[Argument],
		what: &'static str,
		milliseconds: u64,
	) -> impl Future<Output = Result<Argument, Error>> + use<'_, D> {
		let (host, platform) = match self {
			Self::Remote(client) => (client.session().host(), client.platform()),
			Self::Hosted { host, platform, .. } => (host.clone(), platform),
		};
		let pending = host.send(source, verb, args);
		async move {
			platform
				.within(milliseconds, async move { pending.await })
				.await
				.ok_or(Error::Timeout(what))?
				.map_err(Error::from)
		}
	}
	pub fn call(
		&self,
		source: &Ref,
		verb: &'static str,
		args: &[Argument],
		what: &'static str,
	) -> impl Future<Output = Result<Argument, Error>> + use<'_, D> {
		// Both fronts admit the vow now. Temporary arguments retire before the
		// observation awaits. Hosted requests open no transport or session.
		let pending = self.wait(source, verb, args);
		let (platform, session) = match self {
			Self::Remote(client) => (client.platform(), None),
			Self::Hosted { platform, attached, .. } => (platform, attached.as_ref()),
		};
		async move {
			if let Some(reply) = platform.within(REQUEST_TIMEOUT_MS, pending).await {
				return reply;
			}
			let Some(Attached { session, probe }) = session else {
				return Err(Error::Timeout(what));
			};
			let probe = self.wait(session, probe, &[]);
			Err(after_probe(
				platform.within(CALL_BOUND_MS - REQUEST_TIMEOUT_MS, probe).await,
				what,
			))
		}
	}
	pub fn wait(
		&self,
		source: &Ref,
		verb: &'static str,
		args: &[Argument],
	) -> impl Future<Output = Result<Argument, Error>> + use<D> {
		let pending = match self {
			Self::Remote(client) => Pending::Remote(client.session().send(source, verb, args)),
			Self::Hosted { host, .. } => Pending::Hosted(host.send(source, verb, args)),
		};
		let attached = matches!(self, Self::Hosted { attached: Some(_), .. });
		async move {
			let failure = match pending {
				Pending::Remote(pending) => pending.await,
				Pending::Hosted(pending) => pending.await,
			}
			.map_err(Error::from);
			if attached {
				failure.map_err(|error| error.unreached_if_lost("The connection to the session was lost"))
			} else {
				failure
			}
		}
	}
	/// Close the live session that serves `reference`, if one remains, so the
	/// next dial to it opens a new one. A capability served here has no
	/// session, and nothing is closed. A close that outlasts a request's time
	/// is `Error::Unreached`. It goes on in the binding, and the next `retire`
	/// waits on that same close.
	pub async fn retire(&self, reference: &Ref) -> Result<(), Error> {
		let Some(session) = self.host().reference_session(reference)? else {
			return Ok(());
		};
		let bound = REQUEST_TIMEOUT_MS;
		let Some(closed) = self
			.platform()
			.within(bound, session.close(glowcap::PendingWork::Cancel))
			.await
		else {
			return Err(Error::unreached("Closing the stale session timed out"));
		};
		// tolerant: a session that already failed reports its failure again on
		// close, and the connection is gone either way.
		drop(closed);
		Ok(())
	}
}
enum Pending {
	Remote(glowcap::RemotePromise),
	Hosted(glowcap::HostPromise),
}
/// Wait for `turn`, a dial's turn at what another dial or a close may hold,
/// within the part of one call's bound that the dial's own request time
/// leaves. A turn that never comes is `session-not-reached-yet`: the session
/// was never asked, so neither its connection nor its answer is the failure.
pub async fn dial_turn<D: Deadline, T>(platform: &D, turn: impl Future<Output = T>) -> Result<T, FailureCode> {
	platform
		.within(CALL_BOUND_MS - REQUEST_TIMEOUT_MS, turn)
		.await
		.ok_or(FailureCode::SessionNotReachedYet)
}
/// Dial the session that serves a held capability, within one request's
/// time. A dial that runs out of it, or that never reached the session or
/// lost the connection under it, is `Error::Unreached`, which only time
/// clears. `timed_out` names the dial whose time ran out. Any other failure
/// is the binding's, as it came.
pub async fn dial_session<D: Deadline, T>(
	platform: &D,
	timed_out: &'static str,
	dial: impl Future<Output = Result<T, glowcap::Error>>,
) -> Result<T, Error> {
	platform
		.within(REQUEST_TIMEOUT_MS, dial)
		.await
		.ok_or(Error::unreached(timed_out))?
		.map_err(|error| Error::from(error).unreached_if_lost("The session did not answer"))
}
/// What a call to an attached session that missed its deadline fails with,
/// from `probed`, the `Attached::probe` request that asked the session once
/// more, or none when that missed its own deadline. A session that answers
/// still holds the link, and a probe that found the connection lost carries
/// the binding failure it met as the cause. A probe the session refused is
/// about the probe's own request, not the call's, so the call stays timed out
/// with its effect unknown.
fn after_probe(probed: Option<Result<Argument, Error>>, what: &'static str) -> Error {
	match probed {
		Some(Ok(_)) => Error::RequestTimedOut(what),
		Some(Err(error)) if !error.connection_failed() => Error::RequestTimedOut(what),
		Some(Err(Error::Unreached { cause, .. })) => Error::Unreached { detail: what, cause },
		_ => Error::unreached(what),
	}
}

#[cfg(test)]
mod tests {
	use super::{
		CALL_BOUND_MS, Deadline, Error, FailureCode, REQUEST_TIMEOUT_MS, after_probe, dial_session, dial_turn,
	};
	use std::{
		cell::Cell,
		future::Future,
		pin::pin,
		task::{Context, Poll, Waker},
	};

	/// A clock whose bounded waits each come back as `answers` says, keeping
	/// the bound each was given.
	struct Turns {
		answers: bool,
		bound: Cell<Option<u64>>,
	}
	impl Deadline for Turns {
		fn monotonic_millis(&self) -> u64 {
			0
		}
		async fn within<T>(&self, milliseconds: u64, work: impl Future<Output = T>) -> Option<T> {
			self.bound.set(Some(milliseconds));
			if self.answers { Some(work.await) } else { None }
		}
	}

	#[test]
	fn a_dial_waits_for_its_turn_within_what_its_request_leaves_of_the_call() {
		for answers in [true, false] {
			let clock = Turns {
				answers,
				bound: Cell::new(None),
			};
			// Every wait here is ready at once, so one poll finishes the dial's.
			let Poll::Ready(turn) = pin!(dial_turn(&clock, async { 7 })).poll(&mut Context::from_waker(Waker::noop()))
			else {
				panic!("a turn whose clock answers at once is ready at once");
			};
			let expected = if answers {
				Ok(7)
			} else {
				Err(FailureCode::SessionNotReachedYet)
			};
			assert_eq!(turn, expected);
			assert_eq!(clock.bound.get(), Some(CALL_BOUND_MS - REQUEST_TIMEOUT_MS));
		}
	}

	#[test]
	fn a_session_dial_that_runs_out_of_time_or_loses_its_connection_is_unreached() {
		let dialed = |answers: bool, outcome: Result<u8, glowcap::Error>| {
			let clock = Turns {
				answers,
				bound: Cell::new(None),
			};
			// Every wait here is ready at once, so one poll finishes the dial.
			let Poll::Ready(dialed) =
				pin!(dial_session(&clock, "the dial", async { outcome })).poll(&mut Context::from_waker(Waker::noop()))
			else {
				panic!("a dial whose clock answers at once is ready at once");
			};
			assert_eq!(clock.bound.get(), Some(REQUEST_TIMEOUT_MS));
			dialed
		};
		let late = dialed(false, Ok(7));
		assert!(
			matches!(
				late,
				Err(Error::Unreached {
					detail: "the dial",
					cause: None
				})
			),
			"{late:?}"
		);
		let lost = dialed(
			true,
			Err(glowcap::Error::from(std::io::Error::other("the connection broke"))),
		);
		assert!(matches!(lost, Err(Error::Unreached { cause: Some(_), .. })), "{lost:?}");
		for unreached in [late, lost] {
			assert_eq!(
				unreached.err().and_then(|error| error.failure_code()),
				Some(FailureCode::SessionUnreachable)
			);
		}
		let refused = dialed(true, Err(glowcap::loam::refusal("nick-taken: Ann")));
		assert!(matches!(refused, Err(Error::Binding(_))), "{refused:?}");
		assert!(matches!(dialed(true, Ok(7)), Ok(7)));
	}

	#[test]
	fn a_restoration_whose_session_closed_is_a_dial_that_only_time_clears() {
		use glowcap::{BreakCause, BreakReason};
		let closed = BreakCause::local(BreakReason::Closed).with_restoration();
		assert!(super::super::error::clears_with_time(closed));
		let refused = BreakCause::local(BreakReason::Refused).with_restoration();
		assert!(!super::super::error::clears_with_time(refused));
	}

	#[test]
	fn a_probe_that_finds_the_connection_lost_names_the_binding_cause() {
		let broke = glowcap::Error::from(std::io::Error::other("the connection broke"));
		let said = broke.to_string();
		let lost = Error::from(broke).unreached_if_lost("The connection to the session was lost");
		let error = after_probe(Some(Err(lost)), "the call");
		let Error::Unreached {
			detail,
			cause: Some(cause),
		} = &error
		else {
			panic!("the probe's cause was dropped: {error:?}");
		};
		assert_eq!((*detail, cause.to_string()), ("the call", said.clone()));
		assert_eq!(error.to_string(), said);
	}

	#[test]
	fn a_session_that_still_answers_the_probe_keeps_the_link() {
		let refused = Error::from(glowcap::loam::refusal("nick-taken: Ann"));
		assert!(matches!(
			after_probe(Some(Err(refused)), "the call"),
			Error::RequestTimedOut("the call")
		));
		let late = after_probe(None, "the call");
		assert!(
			matches!(
				late,
				Error::Unreached {
					detail: "the call",
					cause: None
				}
			),
			"{late:?}"
		);
	}
}
