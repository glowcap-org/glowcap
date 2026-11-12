//! A signaling exchange reaches only its two ends, within its bounds and deadline.
use super::*;

fn signaling_pair(dir: &mut Dir) {
	let mut alice = request("Alice", "a-inbox");
	alice.host_key = Some("da".into());
	dir.register(1, alice, id(1), 0).expect("registers");
	let mut bob = request("Bob", "b-inbox");
	bob.host_key = Some("db".into());
	dir.register(2, bob, id(2), 0).expect("registers");
}

#[test]
fn an_exchange_routes_between_its_two_ends_only() {
	let mut dir = Dir::default();
	signaling_pair(&mut dir);
	assert_eq!(
		dir.signal_offer(1, "db", "reply", 0).unwrap_err().code,
		Some(FailureCode::PeerOffline)
	);
	assert_eq!(dir.offer_signaling(2, "b-signaling"), Ok(None));
	assert_eq!(
		dir.offer_signaling(2, "b-signaling-2"),
		Ok(Some(Release {
			connection: 2,
			capability: "b-signaling"
		}))
	);
	assert_eq!(
		dir.signal_offer(3, "db", "reply", 0).unwrap_err().code,
		Some(FailureCode::NotRegistered)
	);
	let offered = dir.signal_offer(1, "db", "reply", 0).expect("offers");
	assert_eq!(offered.id, "x0");
	// The target learns the originator by the designator signaling routes it by.
	assert_eq!(offered.from.as_deref(), Some("da"));
	assert_eq!(
		offered.target,
		Route {
			connection: 2,
			capability: "b-signaling-2"
		}
	);
	assert!(offered.dropped.is_empty());
	let to_originator = Route {
		connection: 1,
		capability: "reply",
	};
	assert_eq!(dir.signal_answer(2, "x0"), Ok(Some(to_originator.clone())));
	assert_eq!(dir.signal_answer(2, "x9"), Ok(None));
	assert_eq!(dir.signal_answer(1, "x0").unwrap_err().code, None);
	assert_eq!(
		dir.signal_candidate(1, "x0"),
		Some(Relay::Inbox(offered.target.clone()))
	);
	assert_eq!(dir.signal_candidate(2, "x0"), Some(Relay::Reply(to_originator)));
	assert_eq!(dir.signal_candidate(3, "x0"), None);
	assert_eq!(dir.signal_done(2, "x0"), None);
	let done = dir.signal_done(1, "x0").expect("the originator retires it");
	assert_eq!(done.reason, None);
	assert_eq!(done.reply, "reply");
	assert_eq!(dir.signal_candidate(1, "x0"), None);
	assert_eq!(dir.next_signaling_expiry(), None);
}

#[test]
fn only_the_answering_member_declines_and_the_originator_hears_why() {
	let mut dir = Dir::default();
	signaling_pair(&mut dir);
	dir.offer_signaling(2, "b-signaling").expect("offers");
	dir.signal_offer(1, "db", "reply", 0).expect("offers");
	assert_eq!(dir.signal_decline(1, "x0", "busy").unwrap_err().code, None);
	assert_eq!(dir.signal_decline(2, "x9", "busy"), Ok(None));
	let declined = dir.signal_decline(2, "x0", "busy").expect("declines").expect("drops");
	assert_eq!(declined.reply, "reply");
	assert_eq!(declined.reason.as_deref(), Some("the member declined the offer: busy"));
	assert!(!dir.signaling_open("x0"));
}

#[test]
fn a_repeated_offer_replaces_and_the_oldest_is_evicted_past_the_ceiling() {
	let mut dir = Dir::default();
	signaling_pair(&mut dir);
	dir.offer_signaling(2, "b-signaling").expect("offers");
	dir.signal_offer(1, "db", "reply", 0).expect("offers");
	let again = dir.signal_offer(1, "db", "reply-2", 0).expect("offers again");
	assert_eq!(again.id, "x1");
	assert_eq!(again.dropped.len(), 1);
	assert_eq!(again.dropped[0].id, "x0");
	assert_eq!(again.dropped[0].reply, "reply");
	assert_eq!(
		again.dropped[0].reason.as_deref(),
		Some("signaling exchange was replaced")
	);
	for n in 0..MAX_SIGNAL_EXCHANGES as u32 {
		registered(&mut dir, 100 + n, &format!("m{n}"), "inbox");
		let offered = dir.signal_offer(100 + n, "db", "r", 0).expect("offers");
		assert_eq!(offered.dropped.is_empty(), n + 1 < MAX_SIGNAL_EXCHANGES as u32);
		if !offered.dropped.is_empty() {
			assert_eq!(offered.dropped[0].id, "x1");
			assert_eq!(
				offered.dropped[0].reason.as_deref(),
				Some("signaling exchange was evicted")
			);
		}
	}
}

#[test]
fn an_exchange_times_out_and_the_adapter_learns_when() {
	let mut dir = Dir::default();
	signaling_pair(&mut dir);
	dir.offer_signaling(2, "b-signaling").expect("offers");
	dir.signal_offer(1, "db", "reply", 100).expect("offers");
	assert_eq!(dir.next_signaling_expiry(), Some(100 + SIGNAL_EXCHANGE_TIMEOUT_MS));
	assert!(dir.expire_signaling(100 + SIGNAL_EXCHANGE_TIMEOUT_MS - 1).is_empty());
	let expired = dir.expire_signaling(100 + SIGNAL_EXCHANGE_TIMEOUT_MS);
	assert_eq!(expired.len(), 1);
	assert_eq!(expired[0].reason.as_deref(), Some("signaling exchange timed out"));
	assert_eq!(dir.next_signaling_expiry(), None);
	let failed = dir.signal_offer(1, "db", "reply", 0).expect("offers");
	let dropped = dir.signal_failed(&failed.id, "offer").expect("drops");
	assert_eq!(dropped.reason.as_deref(), Some("offer could not be delivered"));
	assert_eq!(dir.signal_failed(&failed.id, "offer"), None);
}

#[test]
fn a_registration_leaving_drops_the_exchanges_aimed_at_it() {
	let mut dir = Dir::default();
	signaling_pair(&mut dir);
	dir.offer_signaling(2, "b-signaling").expect("offers");
	dir.signal_offer(1, "db", "reply", 0).expect("offers");
	// The target re-registers: the exchange aimed at its old row is told.
	let mut bob = request("Bob", "b-inbox-2");
	bob.host_key = Some("db".into());
	let effects = dir.register(2, bob, id(3), 0).expect("re-registers");
	assert_eq!(effects.dropped.len(), 1);
	assert_eq!(effects.dropped[0].originator, 1);
	assert_eq!(
		effects.dropped[0].reason.as_deref(),
		Some("the member is no longer registered")
	);
	dir.offer_signaling(2, "b-signaling-2").expect("offers");
	dir.signal_offer(1, "db", "reply-2", 0).expect("offers");
	let effects = dir.connection_closed(2);
	assert_eq!(effects.dropped.len(), 1);
	assert_eq!(effects.dropped[0].reply, "reply-2");
	assert!(effects.dropped[0].reason.is_some());
	// The originator closing tells nobody: it is gone.
	let mut bob = request("Bob", "b-inbox-3");
	bob.host_key = Some("db".into());
	dir.register(2, bob, id(4), 0).expect("registers");
	dir.offer_signaling(2, "b-signaling-3").expect("offers");
	dir.signal_offer(1, "db", "reply-3", 0).expect("offers");
	let effects = dir.connection_closed(1);
	assert_eq!(effects.dropped.len(), 1);
	assert_eq!(effects.dropped[0].reason, None);
	assert_eq!(dir.next_signaling_expiry(), None);
}
