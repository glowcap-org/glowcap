//! The signaling verbs: an offer is admitted, delivered, and only then
//! acknowledged; answers and candidates are relayed in the turn they arrive;
//! a delivery the recipient refused retires its exchange with a reason.
use super::{
	behavior::{busy, capability, text, Reply, Shared},
	notice::Notice,
	state::{State, Work},
};
use glowcap::{Argument, Session};
use rooms_application::{
	server::directory::{Relay, MAX_SIGNAL_CANDIDATE, MAX_SIGNAL_ID, MAX_SIGNAL_SDP},
	signaling as signal,
};

const SIG_OFFER: &str = "offer";
const SIG_ACCEPTED: &str = "accepted";
const SIG_ANSWER: &str = "answer";
const SIG_CANDIDATE: &str = "candidate";

/// Whether one relayed message is one to act on. The directory carries it
/// between two members, so its size is the directory's to bound.
fn fits(id: &str, payload: &str, payload_limit: usize) -> bool {
	!id.is_empty() && id.len() <= MAX_SIGNAL_ID && !payload.is_empty() && payload.len() <= payload_limit
}

pub(super) fn dispatch(state: &Shared, connection: u64, verb: &str, args: &[Argument]) -> Reply {
	match verb {
		signal::OFFER_INBOX => offer_signaling(state, connection, args),
		signal::OFFER => offer(state, connection, args),
		signal::ANSWER => answer(state, connection, args),
		signal::CANDIDATE => candidate(state, connection, args),
		_ => done(state, connection, args),
	}
}

fn offer_signaling(state: &Shared, connection: u64, args: &[Argument]) -> Reply {
	let (Some(inbox), 1) = (capability(args, 0), args.len()) else {
		return Err("offerSignaling needs one inbox capability".into());
	};
	let mut state = state.borrow_mut();
	if let Some(replaced) = state
		.policy
		.offer_signaling(connection, inbox.clone())
		.map_err(|refusal| refusal.reason())?
	{
		state.give_back(replaced.connection, replaced.capability);
	}
	Ok(Argument::Void)
}

fn offer(state: &Shared, connection: u64, args: &[Argument]) -> Reply {
	let (designator, sdp) = (text(args, 0).unwrap_or(""), text(args, 1).unwrap_or(""));
	let (Some(reply), 3, true) = (capability(args, 2), args.len(), fits(designator, sdp, MAX_SIGNAL_SDP)) else {
		return Err(format!(
			"signalOffer needs a designator, an offer sdp of at most {MAX_SIGNAL_SDP} bytes, and one reply capability"
		));
	};
	let mut state = state.borrow_mut();
	let state = &mut *state;
	let now = state.now();
	// The delivery's seat is reserved before the exchange is admitted, so a
	// full queue refuses without an exchange nobody will deliver.
	let seat = state.work.try_reserve().map_err(|_| busy())?;
	let offered = state
		.policy
		.signal_offer(connection, designator, reply.clone(), now)
		.map_err(|refusal| refusal.reason())?;
	// Admission is not observable to the originator until the target has
	// taken the offer, so a replaced exchange cannot suppress a delivery that
	// `accepted` already promised, and early ICE waits behind the offer.
	seat.send(Work::Offer {
		id: offered.id,
		target: offered.target,
		sdp: sdp.into(),
		originator: connection,
		reply: reply.clone(),
	});
	for dropped in offered.dropped {
		state.reject(dropped);
	}
	Ok(Argument::Void)
}

fn answer(state: &Shared, connection: u64, args: &[Argument]) -> Reply {
	let (id, sdp) = (text(args, 0).unwrap_or(""), text(args, 1).unwrap_or(""));
	if args.len() != 2 || !fits(id, sdp, MAX_SIGNAL_SDP) {
		return Err(format!("a signaling answer may be at most {MAX_SIGNAL_SDP} bytes"));
	}
	let mut state = state.borrow_mut();
	let route = state
		.policy
		.signal_answer(connection, id)
		.map_err(|refusal| refusal.reason())?;
	if let Some(route) = route {
		if !state.tell(route.connection, &route.capability, SIG_ANSWER, &[sdp.into()]) {
			failed(&mut state, id, "signaling answer");
		}
	}
	Ok(Argument::Void)
}

fn candidate(state: &Shared, connection: u64, args: &[Argument]) -> Reply {
	let (id, ice) = (text(args, 0).unwrap_or(""), text(args, 1).unwrap_or(""));
	if args.len() != 2 || !fits(id, ice, MAX_SIGNAL_CANDIDATE) {
		return Err("signalCandidate needs one exchange id and bounded ICE candidate".into());
	}
	let mut state = state.borrow_mut();
	let delivered = match state.policy.signal_candidate(connection, id) {
		None => return Ok(Argument::Void),
		Some(Relay::Inbox(route)) => state.tell(
			route.connection,
			&route.capability,
			SIG_CANDIDATE,
			&[id.into(), ice.into()],
		),
		Some(Relay::Reply(route)) => state.tell(route.connection, &route.capability, SIG_CANDIDATE, &[ice.into()]),
	};
	if !delivered {
		failed(&mut state, id, "signaling candidate");
	}
	Ok(Argument::Void)
}

fn done(state: &Shared, connection: u64, args: &[Argument]) -> Reply {
	let (Some(id), 1) = (text(args, 0).filter(|id| !id.is_empty()), args.len()) else {
		return Err("signalDone needs one exchange id".into());
	};
	let mut state = state.borrow_mut();
	if let Some(dropped) = state.policy.signal_done(connection, id) {
		state.reject(dropped);
	}
	Ok(Argument::Void)
}

/// A relayed message could not be queued for its recipient: the exchange is
/// retired and its originator told why.
fn failed(state: &mut State, id: &str, what: &str) {
	if let Some(dropped) = state.policy.signal_failed(id, what) {
		state.reject(dropped);
	}
}

/// Deliver an offer and, once its target has taken it, acknowledge it to the
/// originator. Runs outside any turn; the loop owns the task. A target whose
/// connection has already gone is a failed delivery with nobody to report.
pub(super) async fn deliver_offer(
	state: Shared,
	id: String,
	target: (Option<Session>, glowcap::Ref),
	sdp: String,
	originator: u64,
	reply: glowcap::Ref,
) {
	let outcome = match target.0 {
		Some(session) => Some(
			session
				.send(&target.1, SIG_OFFER, &[id.as_str().into(), sdp.into()])
				.await,
		),
		None => None,
	};
	let mut state = state.borrow_mut();
	match outcome {
		Some(Ok(_)) => {
			if state.policy.signaling_open(&id) && !state.tell(originator, &reply, SIG_ACCEPTED, &[id.as_str().into()])
			{
				failed(&mut state, &id, "signaling acceptance");
			}
		}
		Some(Err(cause)) => {
			state.report(Notice::DeliveryFailed {
				what: "signaling offer",
				cause,
			});
			failed(&mut state, &id, "signaling offer");
		}
		None => failed(&mut state, &id, "signaling offer"),
	}
}
