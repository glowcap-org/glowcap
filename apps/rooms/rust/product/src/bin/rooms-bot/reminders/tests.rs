use super::*;
use rooms_testing::scratch::Scratch;

fn create(root: &Path, scope: Scope, request: Request<'_>, at: u64) -> Result<Value, Error> {
	super::create(root, scope, request, at, || Ok(()))
}
fn cancel(root: &Path, scope: &Scope, id: &str) -> Result<Value, Error> {
	super::cancel(root, scope, id, || Ok(()))
}

fn scope(id: &str) -> Scope {
	Scope {
		kind: crate::bot::rooms::Kind::Direct,
		grant: "a".repeat(64),
		conversation: id.into(),
		target: "c".repeat(64),
	}
}
fn request(id: &str) -> Request<'_> {
	Request {
		kind: Kind::Reminder,
		id,
		when: When::After(30),
		repeat: None,
		text: "test reminder",
	}
}

#[test]
fn utc_times_relative_bounds_and_finite_cadence() {
	let when = When::parse(None, Some("2024-02-29T12:34:56Z")).unwrap();
	assert_eq!(when.due(1_709_210_095).unwrap(), 1_709_210_096);
	for date in [
		"2023-02-29T12:34:56Z",
		"2026-02-13T24:00:00Z",
		"2026-11-28 09:00",
		"2026-11-28T09:00:00+0100",
	] {
		assert!(When::parse(None, Some(date)).is_err());
	}
	for value in ["0s", "31d", "-2h", "18446744073709551615d", "1.5m", "1", "1w"] {
		assert!(When::parse(Some(value), None).is_err());
	}
	assert_eq!(When::parse(Some("30d"), None).unwrap().due(1).unwrap(), 1 + HORIZON);
	assert!(when.due(1_709_210_096).is_err());
	assert!(Repeat::parse(Some("59s"), Some("2")).is_err());
	assert!(Repeat::parse(Some("1m"), Some("33")).is_err());
	assert!(Repeat::parse(Some("1m"), None).is_err());
	let root = Scratch::create("reminder-clock");
	let request = Request {
		repeat: Repeat::parse(Some("1d"), Some("32")).unwrap(),
		..request("far")
	};
	assert!(create(&root, scope("a"), request, now()).is_err());
}

#[test]
fn persisted_ids_capacity_and_cancellation_are_scoped_to_the_original_target() {
	let root = Scratch::create("reminder-scope");
	let at = now();
	let here = scope("first");
	let first = create(&root, here.clone(), request("a"), at).unwrap();
	assert_eq!(
		super::create(&root, here.clone(), request("a"), at + 300, || panic!(
			"an identical retry spent another action"
		))
		.unwrap(),
		first
	);
	assert!(
		create(
			&root,
			here.clone(),
			Request {
				text: "changed",
				..request("a")
			},
			at
		)
		.is_err()
	);
	let elsewhere = Scope {
		target: "b".repeat(64),
		..here.clone()
	};
	assert_eq!(list(&root, &elsewhere).unwrap(), json!([]));
	assert!(cancel(&root, &elsewhere, "a").is_err());
	for index in 1..MAX_HERE {
		create(&root, here.clone(), request(&format!("r{index}")), at).unwrap();
	}
	assert!(create(&root, here.clone(), request("full"), at).is_err());
	let stale = Book::read(&root).unwrap().rows[0].clone();
	assert_eq!(cancel(&root, &here, "a").unwrap()["state"], "cancelled");
	assert!(!Book::set(&root, &stale, State::Sending { base: 3 }).unwrap());
	assert_eq!(
		create(&root, here.clone(), request("a"), at + 1).unwrap()["state"],
		"cancelled"
	);
	create(&root, here, request("next"), at).unwrap();
}

#[test]
fn cancelling_twice_spends_once_and_idle_terminal_ids_expire_after_seven_days() {
	let root = Scratch::create("reminder-retention");
	let scope = scope("one");
	let at = now();
	create(&root, scope.clone(), request("key"), at).unwrap();
	cancel(&root, &scope, "key").unwrap();
	super::cancel(&root, &scope, "key", || panic!("retry spent a second action")).unwrap();
	let mut book = Book::read(&root).unwrap();
	let expires = book.rows[0].forget_at().unwrap();
	assert!(!book.prune(expires - 1));
	assert!(book.prune(expires));
	assert!(book.rows.is_empty());
}

#[test]
fn malformed_zero_cadence_cannot_reach_the_timer() {
	let root = Scratch::create("reminder-invalid");
	create(&root, scope("a"), request("id"), now()).unwrap();
	let file = root.join(DIRECTORY).join(FILE);
	let mut book: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
	book["rows"][0]["repeat"] = json!({"count":2,"every_seconds":0});
	std::fs::write(file, serde_json::to_vec(&book).unwrap()).unwrap();
	assert!(matches!(Book::read(&root), Err(Error::Unreadable { .. })));
}

#[test]
fn a_reminder_transaction_cannot_remove_a_live_serve_staging_file() {
	let root = Scratch::create("reminder-separate-lease");
	let store = store::Store::open(&root).unwrap();
	let (staged, _handle) = atomic::staged(store.root(), "turns.json").unwrap();
	create(store.root(), scope("here"), request("fresh"), now()).unwrap();
	assert!(staged.is_file(), "the reminder lease swept a staged turn ledger");
	assert!(store.root().join(DIRECTORY).join(FILE).is_file());
}

#[test]
fn a_deferred_occurrence_wakes_for_capacity_cadence_or_expiry_and_can_be_cancelled() {
	let root = Scratch::create("reminder-deferral");
	let here = scope("chat");
	let at = now();
	create(
		&root,
		here.clone(),
		Request {
			kind: Kind::CheckIn,
			..request("review")
		},
		at,
	)
	.unwrap();
	let mut row = Book::read(&root).unwrap().rows.remove(0);
	let retry_at = row.due + 4000;
	let waiting = State::Deferred {
		retry_at,
		reason: Delay::HourlyLimit { limit: 2 },
	};
	assert!(Book::set(&root, &row, waiting.clone()).unwrap());
	row.state = waiting;
	assert_eq!(row.wake_at(2), retry_at);
	assert_eq!(row.wake_at(3), row.due);
	assert!(pending_check_ins(&root).unwrap().live.contains(&row.operation));
	let listed = list(&root, &here).unwrap();
	assert_eq!(listed[0]["state"], "waiting-for-hourly-limit");
	assert_eq!(listed[0]["retry_at"], stamp::rfc3339(retry_at));
	assert_eq!(cancel(&root, &here, "review").unwrap()["state"], "cancelled");
	assert!(!pending_check_ins(&root).unwrap().live.contains(&row.operation));
	row.repeat = Repeat::parse(Some("1m"), Some("2")).unwrap();
	assert_eq!(row.wake_at(2), row.due + 60);
	row.repeat = None;
	row.state = State::Deferred {
		retry_at: row.due + OVERDUE + 10,
		reason: Delay::WorkerBusy,
	};
	assert_eq!(row.wake_at(2), row.due + OVERDUE + 1);
	assert_eq!(row.report()["state"], "waiting-for-worker");
}
