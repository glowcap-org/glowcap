//! The directory policy read as values: every verb's refusal and every
//! effect it hands the adapter, without a wire.
mod discovery;
mod openings;
mod retirement;
use super::*;
use crate::directory::{MAX_ROWS, MemberChange};
use alloc::{format, vec};

type Dir = Directory<u32, &'static str>;

fn id(n: u32) -> Id {
	Id::parse(&format!("{n:08x}-0000-4000-8000-000000000000")).expect("a v4 uuid")
}

fn request(nick: &str, inbox: &'static str) -> Register<&'static str> {
	Register {
		nick: nick.into(),
		allocation: crate::directory::registration::NicknameAllocation::Exact,
		locator: "ocapn://peer.tcp".into(),
		own_locator: true,
		host_key: None,
		inbox,
		voucher: None,
		claimant: None,
	}
}

fn automatic(nick: &str, inbox: &'static str) -> Register<&'static str> {
	let mut request = request(nick, inbox);
	request.allocation = crate::directory::registration::NicknameAllocation::Automatic;
	request
}

fn registered(dir: &mut Dir, connection: u32, nick: &str, inbox: &'static str) -> Effects<u32, &'static str> {
	dir.register(connection, request(nick, inbox), id(connection), 0)
		.expect("registers")
}

fn member_event(event: &Event) -> Option<(bool, &str, u64)> {
	match event {
		Event::Member { kind, peer, count } => Some((
			matches!(kind, MemberChange::Registered),
			peer.name.text().as_str().expect("utf-8 nick"),
			*count,
		)),
		_ => None,
	}
}

#[test]
fn register_files_a_name_and_announces_it() {
	let mut dir = Dir::default();
	let effects = registered(&mut dir, 1, "Alice", "a-inbox");
	assert_eq!(
		effects.tells,
		vec![Tell {
			connection: 1,
			inbox: "a-inbox",
			notice: Notice::Registered {
				nick: "Alice".into(),
				id: id(1)
			}
		}]
	);
	assert!(effects.releases.is_empty());
	assert_eq!(effects.events.len(), 1);
	assert_eq!(member_event(&effects.events[0]), Some((true, "Alice", 1)));
	assert_eq!(dir.registered_nick(1), Some("Alice"));
	assert_eq!(dir.member_registration("alice"), Ok(id(1)));
}

#[test]
fn automatic_registration_atomically_allocates_the_first_free_name() {
	let mut dir = Dir::default();
	registered(&mut dir, 1, "guest", "one");
	registered(&mut dir, 2, "GUEST-2", "two");
	let effects = dir
		.register(3, automatic("guest", "three"), id(3), 0)
		.expect("allocates after folded collisions");
	assert_eq!(dir.registered_nick(3), Some("guest-3"));
	assert!(matches!(
		&effects.tells[0].notice,
		Notice::Registered { nick, id: granted } if nick == "guest-3" && granted == &id(3)
	));
}

#[test]
fn automatic_registration_is_stable_for_the_same_claimant() {
	let mut dir = Dir::default();
	registered(&mut dir, 1, "guest", "one");
	let mut first = automatic("guest", "first");
	first.claimant = Some("durable-peer".into());
	dir.register(2, first, id(2), 0).expect("allocates");
	let mut retry = automatic("guest", "retry");
	retry.claimant = Some("durable-peer".into());
	dir.register(3, retry, id(3), 0).expect("reclaims the allocation");
	assert_eq!(dir.registered_nick(2), None);
	assert_eq!(dir.registered_nick(3), Some("guest-2"));
}

#[test]
fn automatic_suffixes_respect_the_utf16_nickname_limit() {
	let mut dir = Dir::default();
	let full = "😀".repeat(16);
	registered(&mut dir, 1, &full, "one");
	dir.register(2, automatic(&full, "two"), id(2), 0)
		.expect("truncates before suffixing");
	let expected = format!("{}-2", "😀".repeat(15));
	assert_eq!(dir.registered_nick(2), Some(expected.as_str()));
}

#[test]
fn register_refuses_a_bad_name_or_an_unproved_locator() {
	let mut dir = Dir::default();
	let long = "x".repeat(33);
	let refusal = dir.register(1, request(&long, "i"), id(1), 0).unwrap_err();
	assert_eq!(refusal.code, Some(FailureCode::NickTooLong));
	assert_eq!(refusal.reason(), "nick-too-long: a name may be at most 32 characters");
	let mut unproved = request("Alice", "i");
	unproved.own_locator = false;
	let refusal = dir.register(1, unproved, id(1), 0).unwrap_err();
	assert_eq!(refusal.code, Some(FailureCode::NotYourLocator));
	assert_eq!(dir.registered_nick(1), None);
}

#[test]
fn a_name_another_connection_holds_needs_a_current_voucher() {
	let mut dir = Dir::default();
	registered(&mut dir, 1, "Alice", "a-inbox");
	let refusal = dir.register(2, request("alice", "b-inbox"), id(2), 0).unwrap_err();
	assert_eq!(refusal.code, Some(FailureCode::NickTaken));
	let voucher = [7u8; NAME_VOUCHER_BYTES];
	dir.voucher(&id(1), voucher).expect("the holder mints a voucher");
	let mut carried = request("alice", "b-inbox");
	carried.voucher = Some(voucher);
	let effects = dir
		.register(2, carried.clone(), id(2), 0)
		.expect("a voucher carries the name");
	assert_eq!(
		effects.releases,
		vec![Release {
			connection: 1,
			capability: "a-inbox"
		}]
	);
	assert_eq!(member_event(&effects.events[0]), Some((false, "Alice", 0)));
	assert_eq!(member_event(&effects.events[1]), Some((true, "alice", 1)));
	assert_eq!(dir.registered_nick(1), None);
	assert_eq!(dir.registered_nick(2), Some("alice"));
	// The voucher was spent, and the old name capability is no longer current. status-allow: lifecycle transition; replacement state identity
	let refusal = dir.register(3, carried, id(3), 0).unwrap_err();
	assert_eq!(refusal.code, Some(FailureCode::NickTaken));
	assert_eq!(dir.voucher(&id(1), voucher).unwrap_err().code, None);
}

#[test]
fn vouchers_are_bounded_per_name() {
	let mut dir = Dir::default();
	registered(&mut dir, 1, "Alice", "a-inbox");
	for n in 0..MAX_NAME_VOUCHERS {
		dir.voucher(&id(1), [n as u8; NAME_VOUCHER_BYTES])
			.expect("under the cap");
	}
	let refusal = dir.voucher(&id(1), [99; NAME_VOUCHER_BYTES]).unwrap_err();
	assert_eq!(refusal.code, None);
	assert_eq!(refusal.reason(), "a name may have at most 8 vouchers outstanding");
}

#[test]
fn a_connection_holds_one_name_at_a_time() {
	let mut dir = Dir::default();
	registered(&mut dir, 1, "Alice", "a-inbox");
	let effects = registered(&mut dir, 1, "Bob", "b-inbox");
	assert_eq!(
		effects.releases,
		vec![Release {
			connection: 1,
			capability: "a-inbox"
		}]
	);
	assert_eq!(dir.registered_nick(1), Some("Bob"));
	assert_eq!(
		dir.member_registration("Alice").unwrap_err().code,
		Some(FailureCode::PeerOffline)
	);
}

#[test]
fn a_proved_peer_reconnecting_replaces_its_own_rows() {
	let mut dir = Dir::default();
	let mut first = request("Alice", "a-inbox");
	first.claimant = Some("key-a".into());
	dir.register(1, first, id(1), 0).expect("registers");
	let mut again = request("Alice", "a-inbox-2");
	again.claimant = Some("key-a".into());
	let effects = dir
		.register(2, again, id(2), 0)
		.expect("the same peer takes its name back");
	assert_eq!(
		effects.releases,
		vec![Release {
			connection: 1,
			capability: "a-inbox"
		}]
	);
	assert_eq!(dir.registered_nick(1), None);
	assert_eq!(dir.registered_nick(2), Some("Alice"));
	// A different name from the same peer withdraws the stale one too.
	let mut renamed = request("Alicia", "a-inbox-3");
	renamed.claimant = Some("key-a".into());
	let effects = dir.register(3, renamed, id(3), 0).expect("registers");
	assert_eq!(effects.releases[0].capability, "a-inbox-2");
	assert_eq!(dir.registered_nick(2), None);
}

#[test]
fn a_webrtc_designator_belongs_to_its_first_writer() {
	let mut dir = Dir::default();
	let mut alice = request("Alice", "a-inbox");
	alice.host_key = Some("designator".into());
	dir.register(1, alice.clone(), id(1), 0).expect("registers");
	let mut bob = request("Bob", "b-inbox");
	bob.host_key = Some("designator".into());
	let refusal = dir.register(2, bob, id(2), 0).unwrap_err();
	assert_eq!(refusal.code, Some(FailureCode::NotYourLocator));
	// The holder may re-register with it.
	dir.register(1, alice, id(3), 0).expect("re-registers");
	assert_eq!(dir.member_registration("Alice"), Ok(id(3)));
}

#[test]
fn an_introduction_waits_for_an_offered_inbox() {
	let mut dir = Dir::default();
	registered(&mut dir, 1, "Alice", "a-inbox");
	registered(&mut dir, 2, "Bob", "b-inbox");
	let pending = Tell {
		connection: 1,
		inbox: "a-inbox",
		notice: Notice::MintInboxFor {
			nick: "Bob".into(),
			id: id(2),
			opening: "opening".into(),
		},
	};
	assert_eq!(
		dir.introduce(2, "Alice", id(1).as_str(), "opening"),
		Ok(Introduction::Pending(pending))
	);
	let effects = dir
		.offer_inbox(1, "Bob", id(2).as_str(), "opening", "for-bob")
		.expect("offers");
	assert_eq!(
		effects.tells,
		vec![Tell {
			connection: 2,
			inbox: "b-inbox",
			notice: Notice::Introducible {
				nick: "Alice".into(),
				id: id(1),
				opening: "opening".into()
			}
		}]
	);
	assert_eq!(
		dir.introduce(2, "Alice", id(1).as_str(), "opening"),
		Ok(Introduction::Inbox("for-bob"))
	);
	// Introduction consumed the offer. Re-offering retains a fresh occurrence.
	let effects = dir
		.offer_inbox(1, "Bob", id(2).as_str(), "opening", "for-bob-2")
		.expect("offers");
	assert_eq!(effects.releases, vec![]);
	assert_eq!(
		dir.introduce(3, "Alice", id(1).as_str(), "opening").unwrap_err().code,
		Some(FailureCode::NotRegistered)
	);
	assert_eq!(
		dir.offer_inbox(1, "Bob", id(9).as_str(), "opening", "stale")
			.unwrap_err()
			.code,
		Some(FailureCode::PeerOffline)
	);
	assert_eq!(
		dir.offer_inbox(3, "Bob", id(2).as_str(), "opening", "x")
			.unwrap_err()
			.code,
		Some(FailureCode::NotRegistered)
	);
}

#[test]
fn withdrawal_returns_every_inbox_pointing_at_the_name() {
	let mut dir = Dir::default();
	registered(&mut dir, 1, "Alice", "a-inbox");
	registered(&mut dir, 2, "Bob", "b-inbox");
	dir.offer_inbox(1, "Bob", id(2).as_str(), "opening", "for-bob")
		.expect("offers");
	dir.offer_inbox(2, "Alice", id(1).as_str(), "opening", "for-alice")
		.expect("offers");
	dir.offer_signaling(2, "b-signaling").expect("offers signaling");
	let effects = dir.connection_closed(2);
	let mut releases = effects.releases.clone();
	releases.sort_by_key(|release| (release.connection, release.capability));
	assert_eq!(
		releases,
		vec![
			Release {
				connection: 1,
				capability: "for-bob"
			},
			Release {
				connection: 2,
				capability: "b-inbox"
			},
			Release {
				connection: 2,
				capability: "b-signaling"
			},
			Release {
				connection: 2,
				capability: "for-alice"
			},
		]
	);
	assert_eq!(member_event(&effects.events[0]), Some((false, "Bob", 0)));
	assert_eq!(
		dir.introduce(1, "Bob", id(2).as_str(), "opening").unwrap_err().code,
		Some(FailureCode::PeerOffline)
	);
	// Closing a connection that registered nothing does nothing.
	assert_eq!(dir.connection_closed(2), Effects::default());
}

#[test]
fn offered_inboxes_are_bounded_per_member() {
	let mut dir = Dir::default();
	registered(&mut dir, 1, "Alice", "a-inbox");
	for n in 0..MAX_DM_INBOXES as u32 {
		registered(&mut dir, 10 + n, &format!("m{n}"), "inbox");
		dir.offer_inbox(1, &format!("m{n}"), id(10 + n).as_str(), "opening", "offered")
			.expect("under the cap");
	}
	registered(&mut dir, 9999, "last", "inbox");
	let refusal = dir
		.offer_inbox(1, "last", id(9999).as_str(), "opening", "offered")
		.unwrap_err();
	assert_eq!(refusal.code, None);
	// Replacing one already offered stays admitted.
	dir.offer_inbox(1, "m0", id(10).as_str(), "opening", "again")
		.expect("replaces");
}

#[test]
fn a_direct_request_is_told_once_per_window() {
	let mut dir = Dir::default();
	registered(&mut dir, 1, "Alice", "a-inbox");
	registered(&mut dir, 2, "Bob", "b-inbox");
	let told = Tell {
		connection: 1,
		inbox: "a-inbox",
		notice: Notice::DirectRequested {
			nick: "Bob".into(),
			id: id(2),
		},
	};
	assert_eq!(
		dir.request_direct(2, "Alice", id(1).as_str(), 0),
		Ok(Some(told.clone()))
	);
	assert_eq!(dir.request_direct(2, "Alice", id(1).as_str(), 999), Ok(None));
	assert_eq!(dir.request_direct(2, "Alice", id(1).as_str(), 1000), Ok(Some(told)));
	assert_eq!(
		dir.request_direct(3, "Alice", id(1).as_str(), 0).unwrap_err().code,
		Some(FailureCode::NotRegistered)
	);
}

#[test]
fn watching_answers_a_baseline_and_replaces_a_prior_observer() {
	let mut dir = Dir::default();
	registered(&mut dir, 1, "bob", "b-inbox");
	registered(&mut dir, 2, "Alice", "a-inbox");
	let (snapshot, replaced) = dir
		.watch(3, "observer", Shape::Baseline, core::iter::empty())
		.expect("watches");
	assert!(replaced.is_none());
	assert!(snapshot.rooms.is_empty());
	assert_eq!(snapshot.omitted, 0);
	let names: Vec<&str> = snapshot
		.peers
		.iter()
		.map(|peer| peer.name.text().as_str().expect("utf-8"))
		.collect();
	assert_eq!(names, ["Alice", "bob"]);
	let (_, replaced) = dir
		.watch(3, "observer-2", Shape::Publication, core::iter::empty())
		.expect("watches again");
	assert_eq!(
		replaced,
		Some(Release {
			connection: 3,
			capability: "observer"
		})
	);
	let watching: Vec<(u32, &str, Shape)> = dir.watchers().map(|(c, r, s)| (c, *r, s)).collect();
	assert_eq!(watching, [(3, "observer-2", Shape::Publication)]);
	let effects = dir.connection_closed(3);
	assert_eq!(
		effects.releases,
		vec![Release {
			connection: 3,
			capability: "observer-2"
		}]
	);
	assert_eq!(dir.watchers().count(), 0);
}

#[test]
fn watchers_and_snapshot_rows_are_bounded() {
	let mut dir = Dir::default();
	for n in 0..MAX_WATCHERS as u32 {
		dir.watch(n, "o", Shape::Baseline, core::iter::empty())
			.expect("under the cap");
	}
	let refusal = dir
		.watch(MAX_WATCHERS as u32, "o", Shape::Baseline, core::iter::empty())
		.unwrap_err();
	assert_eq!(refusal.code, None);
	dir.watch(0, "o2", Shape::Baseline, core::iter::empty())
		.expect("a seat re-taken");
	let extra = 3;
	for n in 0..(MAX_ROWS + extra) as u32 {
		registered(&mut dir, 1000 + n, &format!("m{n}"), "inbox");
	}
	let snapshot = dir.snapshot(Shape::Baseline, core::iter::empty());
	assert_eq!(snapshot.peers.len(), MAX_ROWS);
	assert_eq!(snapshot.omitted, extra as u64);
}

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

#[test]
fn a_fresh_id_is_a_version_four_uuid() {
	let id = Id::from_entropy([0xff; 16]);
	assert_eq!(id.as_str(), "ffffffff-ffff-4fff-bfff-ffffffffffff");
	assert_eq!(Id::parse(id.as_str()), Ok(id));
}

#[test]
fn inbox_settlement_cannot_cross_a_registration_replacement_or_directory() {
	let mut dir = Dir::default();
	registered(&mut dir, 1, "Alice", "a-inbox");
	registered(&mut dir, 2, "Bob", "b-inbox");
	let pending = dir.prepare_inbox(1, "Bob", id(2).as_str(), "opening").unwrap();
	dir.register(1, request("Alice", "new-a"), id(3), 0).unwrap();
	assert_eq!(
		dir.complete_inbox(pending, "late").unwrap_err().code,
		Some(FailureCode::NotRegistered)
	);
	assert!(matches!(
		dir.introduce(2, "Alice", id(3).as_str(), "opening").unwrap(),
		Introduction::Pending(_)
	));
	let pending = dir.prepare_inbox(1, "Bob", id(2).as_str(), "opening").unwrap();
	dir.register(2, request("Bob", "new-b"), id(4), 0).unwrap();
	assert_eq!(
		dir.complete_inbox(pending, "late").unwrap_err().code,
		Some(FailureCode::PeerOffline)
	);
	let mut other = Dir::default();
	other.register(1, request("Alice", "new-a"), id(3), 0).unwrap();
	other.register(2, request("Bob", "new-b"), id(4), 0).unwrap();
	let pending = dir.prepare_inbox(1, "Bob", id(4).as_str(), "opening").unwrap();
	assert!(other.complete_inbox(pending, "foreign").is_err());
	let current = dir.prepare_inbox(1, "Bob", id(4).as_str(), "opening").unwrap();
	let effects = dir.complete_inbox(current, "ready").unwrap();
	assert_eq!(effects.tells.len(), 1);
	assert_eq!(
		dir.introduce(2, "Alice", id(3).as_str(), "opening"),
		Ok(Introduction::Inbox("ready"))
	);
}
