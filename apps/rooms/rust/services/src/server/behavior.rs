//! The directory root shared by all connections. Every verb reads its
//! arguments, asks the policy, and applies what the policy answered; the
//! verbs that take capabilities are the only ones that accept them.
use super::{
	registration, signaling,
	state::{State, Work},
};
use glowcap::{Argument, Ref, current_session};
use rooms_application::{
	directory::{LIST, NAME as DIRECTORY, Shape, WATCH, creation, registration as member, wire},
	failure::FailureCode,
	room::ArgumentView,
	server::directory::Introduction,
	signaling as signal,
};
use rooms_glowcap::{Value, snapshot::Arguments};
use std::{cell::RefCell, rc::Rc};

pub(super) type Shared = Rc<RefCell<State>>;
pub(super) type Reply = Result<Argument, String>;

const LIST_BASELINE: &str = rooms_application::protocol_data::LIST;
const WATCH_BASELINE: &str = rooms_application::protocol_data::WATCH;
const INTRODUCE: &str = rooms_application::protocol_data::INTRODUCE;

/// The verbs whose arguments may carry a capability, and which one.
fn takes_capability(verb: &str) -> bool {
	matches!(
		verb,
		member::REGISTER | member::OFFER_INBOX | WATCH_BASELINE | WATCH | signal::OFFER_INBOX | signal::OFFER
	)
}

/// Publish before listeners open; the calling session identifies the policy
/// owner even when a first turn precedes the accept loop's bookkeeping.
pub(super) fn root(state: Shared) -> impl FnMut(&str, &[Argument]) -> Reply {
	move |verb, args| {
		let (connection, _) = super::rooms::caller(&mut state.borrow_mut())?;
		if !takes_capability(verb) && args.iter().any(|arg| Value(arg).contains_capability()) {
			return Err(format!("directory {verb} does not take capability arguments"));
		}
		match verb {
			LIST_BASELINE | LIST => list(&state, args, shape_of(verb)),
			WATCH_BASELINE | WATCH => watch(&state, connection, args, shape_of(verb)),
			creation::OPEN
			| creation::OPEN_MANAGED
			| creation::ENTER
			| creation::ENTER_PUBLICATION
			| creation::LINK
			| creation::PRIVATE_LINK => super::rooms::directory_verb(&state, connection, verb, args),
			member::REGISTER => registration::register(&state, connection, args),
			member::OFFER_INBOX => offer_inbox(&state, connection, args),
			INTRODUCE => introduce(&state, connection, args),
			member::REQUEST_DIRECT => request_direct(&state, connection, args),
			member::MEMBER => member_registration(&state, args),
			creation::LOCATION => location(&state, args),
			signal::OFFER_INBOX | signal::OFFER | signal::ANSWER | signal::CANDIDATE | signal::DONE => {
				signaling::dispatch(&state, connection, verb, args)
			}
			_ => Err(format!("unknown {DIRECTORY} method {verb}")),
		}
	}
}

fn shape_of(verb: &str) -> Shape {
	if verb == LIST || verb == WATCH {
		Shape::Publication
	} else {
		Shape::Baseline
	}
}

pub(super) fn text(args: &[Argument], at: usize) -> Option<&str> {
	args.get(at).and_then(Argument::as_str)
}

pub(super) fn capability(args: &[Argument], at: usize) -> Option<&Ref> {
	match args.get(at) {
		Some(Argument::Reference(reference)) => Some(reference),
		_ => None,
	}
}

fn list(state: &Shared, args: &[Argument], shape: Shape) -> Reply {
	if !args.is_empty() {
		return Err(format!(
			"{} takes no arguments",
			if shape == Shape::Publication {
				LIST
			} else {
				LIST_BASELINE
			}
		));
	}
	let rows: Vec<_> = state.borrow().listed().collect();
	Ok(wire::rooms::<Arguments>(&rows, shape))
}

fn watch(state: &Shared, connection: u64, args: &[Argument], shape: Shape) -> Reply {
	let (Some(observer), 1) = (capability(args, 0), args.len()) else {
		return Err("watch needs exactly one inbox capability".into());
	};
	let mut state = state.borrow_mut();
	let listed: Vec<_> = state.listed().collect();
	let (snapshot, replaced) = {
		let State { policy, .. } = &mut *state;
		policy
			.watch(connection, observer.clone(), shape, listed.into_iter())
			.map_err(|refusal| refusal.reason())?
	};
	if let Some(replaced) = replaced {
		state.give_back(replaced.connection, replaced.capability);
	}
	Ok(wire::snapshot::<Arguments>(&snapshot, shape))
}

fn offer_inbox(state: &Shared, connection: u64, args: &[Argument]) -> Reply {
	let (Some(offered), 3) = (capability(args, 2), args.len()) else {
		return Err("offerInbox needs a nick, registration ID, and inbox capability".into());
	};
	let (nick, id) = (text(args, 0).unwrap_or(""), text(args, 1).unwrap_or(""));
	let offer = state
		.borrow()
		.policy
		.prepare_inbox(connection, nick, id)
		.map_err(|r| r.reason())?;
	let caller = current_session()
		.map_err(|e| e.to_string())?
		.ok_or("offerInbox is reachable only over a session")?
		.borrowed();
	let offered = offered.clone();
	let owner = state.clone();
	super::answer::later(&state.borrow(), member::OFFER_INBOX, async move {
		let value = caller.resolve(&offered).await.map_err(|e| e.to_string())?;
		let inbox = Ref::try_from(&value).map_err(|()| "offered inbox did not resolve to a capability")?;
		let mut state = owner.borrow_mut();
		// The registration generation is checked again after settlement. A
		// delayed handoff cannot publish into a replacement member's inbox.
		let effects = state.policy.complete_inbox(offer, inbox).map_err(|r| r.reason())?;
		state.apply(effects);
		Ok(Argument::Void)
	})
}

fn introduce(state: &Shared, connection: u64, args: &[Argument]) -> Reply {
	if args.len() != 2 {
		return Err("introduce takes a valid registered name and its registration ID".into());
	}
	let (nick, id) = (text(args, 0).unwrap_or(""), text(args, 1).unwrap_or(""));
	let state = state.borrow();
	match state
		.policy
		.introduce(connection, nick, id)
		.map_err(|refusal| refusal.reason())?
	{
		// A reference homed on the member's own connection: the Host hands
		// the caller a gift, never a relay through this process.
		Introduction::Inbox(inbox) => Ok(Argument::Reference(inbox)),
		Introduction::Pending(tell) => {
			// The caller is told to come back only after the member has taken
			// the request, so the answer waits on that delivery. The seat is
			// reserved before the turn is deferred, so a full queue refuses in
			// the turn rather than abandoning a deferred answer.
			let seat = state.reserve().ok_or_else(busy)?;
			let caller = current_session()
				.map_err(|e| e.to_string())?
				.ok_or("introduce is reachable only over a session")?
				.borrowed();
			let resolver = caller.host().defer_turn().map_err(|e| e.to_string())?;
			let caller_nick = state.policy.registered_nick(connection).unwrap_or("").to_owned();
			let pending = format!(
				"{}: \"{nick}\" has been asked for an inbox for \"{caller_nick}\"; try again",
				FailureCode::IntroductionPending.wire()
			);
			let offline = format!(
				"{}: \"{nick}\" could not be reached for direct messages",
				FailureCode::PeerOffline.wire()
			);
			seat.send(Work::Introduce {
				target: tell,
				caller,
				resolver,
				pending,
				offline,
			});
			Ok(Argument::Void)
		}
	}
}

fn request_direct(state: &Shared, connection: u64, args: &[Argument]) -> Reply {
	if args.len() != 2 {
		return Err("requestDirect takes a valid registered name and its registration ID".into());
	}
	let (nick, id) = (text(args, 0).unwrap_or(""), text(args, 1).unwrap_or(""));
	let mut state = state.borrow_mut();
	let now = state.now();
	if let Some(tell) = state
		.policy
		.request_direct(connection, nick, id, now)
		.map_err(|refusal| refusal.reason())?
	{
		state.tell_member(&tell);
	}
	Ok(Argument::Void)
}

fn member_registration(state: &Shared, args: &[Argument]) -> Reply {
	if args.len() != 1 {
		return Err("memberRegistration takes one valid registered name".into());
	}
	let id = state
		.borrow()
		.policy
		.member_registration(text(args, 0).unwrap_or(""))
		.map_err(|refusal| refusal.reason())?;
	Ok(id.as_str().into())
}

fn location(state: &Shared, args: &[Argument]) -> Reply {
	if !args.is_empty() {
		return Err(format!("{} takes no arguments", creation::LOCATION));
	}
	let caller = current_session().map_err(|e| e.to_string())?;
	let locator = state.borrow().advertised_locator(caller.as_ref());
	// Rooms keeps the concrete TCP address spelling for baseline callers.
	// Full identity routes and other transports retain their complete URI.
	if locator.transport == glowcap::TRANSPORT_TCP {
		return Ok(locator.designator.into());
	}
	glowcap::format_locator_uri(&locator)
		.map_err(|e| e.to_string())
		.map(Argument::from)
}

/// The delivery queue is full: the caller retries rather than the directory
/// growing a queue on its word.
pub(super) fn busy() -> String {
	"the directory is busy relaying; try again".into()
}
