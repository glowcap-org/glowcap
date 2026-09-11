//! An admitted identity change belongs to one network incarnation, not to
//! whichever channel happened to receive the form. Surviving siblings restore
//! the prior identity after either synchronous opening or registration failure.
use super::*;

fn current(state: &State, connection: u64, network: &str, incarnation: u64) -> bool {
	state
		.irc
		.core
		.borrow()
		.identity(connection, network)
		.is_some_and(|identity| identity.incarnation == incarnation)
}
fn open_current(state: &mut State, connection: u64, network: &str, incarnation: u64) -> Result<Rc<Identity>, String> {
	if !current(state, connection, network, incarnation) {
		return Err("this IRC identity ended".into());
	}
	let (publication, seat) = seats(state, connection, network)
		.into_iter()
		.next()
		.ok_or("this IRC identity has no remaining participant")?;
	open(state, &publication, &seat)
}

pub(in crate::room_server::irc::members) async fn change(
	shared: &Shared,
	publication: &Rc<Publication>,
	seat: &Rc<Seat>,
	replacement: Option<seat::Identity>,
) -> Result<String, String> {
	let (network, gate) = {
		let mut state = shared.borrow_mut();
		valid(&state, publication, seat)?;
		let network = network(&state, publication)?;
		let gate = gate(&mut state, seat.connection, &network);
		(network, gate)
	};
	let _held = gate.lock_owned().await;
	let (prior, old) = {
		let mut state = shared.borrow_mut();
		valid(&state, publication, seat)?;
		let prior = state
			.irc
			.core
			.borrow()
			.identity(seat.connection, &network)
			.ok_or("this IRC identity ended")?
			.clone();
		let old = detach(&mut state, seat.connection, &network);
		(prior, old)
	};
	if let Some(old) = old {
		if let Err(reason) = old.member.close().await {
			trouble(&shared.borrow(), "closing the prior IRC identity", reason);
		}
	}
	let opened = {
		let mut state = shared.borrow_mut();
		if !current(&state, seat.connection, &network, prior.incarnation) {
			return Err("this IRC identity ended".into());
		}
		{
			let mut core = state.irc.core.borrow_mut();
			let claimed = core
				.identity_mut(seat.connection, &network)
				.expect("current incarnation");
			claimed.enabled = replacement.is_some();
			claimed.sasl = replacement.as_ref().and_then(|replacement| replacement.sasl.clone());
			if let Some(replacement) = &replacement {
				claimed.irc_nick = replacement.nick.clone();
			}
		}
		if replacement.is_none() {
			show_all(&state, seat.connection, &network, Phase::Rooms, Some(&prior.irc_nick));
			return Ok(seat::disconnected_said(&network));
		}
		open_current(&mut state, seat.connection, &network, prior.incarnation)
	};
	let result = match opened {
		Ok(identity) => join_all(shared, seat.connection, &network, identity).await,
		Err(reason) => Err(reason),
	};
	let Err(reason) = result else {
		if !current(&shared.borrow(), seat.connection, &network, prior.incarnation) {
			return Err("this IRC identity ended".into());
		}
		return Ok(seat::linked_said(&network, replacement.as_ref().expect("linking")));
	};
	let failed = {
		let mut state = shared.borrow_mut();
		if !current(&state, seat.connection, &network, prior.incarnation) {
			return Err(reason);
		}
		detach(&mut state, seat.connection, &network)
	};
	if let Some(failed) = failed {
		if let Err(cleanup) = failed.member.close().await {
			trouble(&shared.borrow(), "closing the failed IRC identity", cleanup);
		}
	}
	let restored = {
		let mut state = shared.borrow_mut();
		if !current(&state, seat.connection, &network, prior.incarnation) {
			return Err(reason);
		}
		{
			let mut core = state.irc.core.borrow_mut();
			let claimed = core
				.identity_mut(seat.connection, &network)
				.expect("current incarnation");
			claimed.irc_nick = prior.irc_nick.clone();
			claimed.sasl = prior.sasl;
			claimed.enabled = prior.enabled;
		}
		if !prior.enabled {
			show_all(&state, seat.connection, &network, Phase::Rooms, Some(&prior.irc_nick));
			return Err(reason);
		}
		open_current(&mut state, seat.connection, &network, prior.incarnation)
	};
	let rollback = match restored {
		Ok(identity) => join_all(shared, seat.connection, &network, identity).await,
		Err(rollback) => {
			let state = shared.borrow();
			if current(&state, seat.connection, &network, prior.incarnation) {
				show_all(&state, seat.connection, &network, Phase::Failed, Some(&prior.irc_nick));
			}
			Err(rollback)
		}
	};
	if let Err(rollback) = rollback {
		trouble(&shared.borrow(), "restoring the prior IRC identity", rollback.clone());
		return Err(format!("{reason}; restoring the prior IRC identity failed: {rollback}"));
	}
	Err(reason)
}
