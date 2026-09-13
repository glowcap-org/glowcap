use rooms_application::documents::WriteFailure;
use rooms_application::grants::{
	Access, ApplyError, Change, Command, Error, GrantLedger, GrantStorage, MAX_ACTIVE_GRANTS, MAX_DOCUMENT_BYTES,
	MAX_LIFETIME_GRANTS, PolicyPatch, Rights, derive_entropy,
};
use serde_json::json;

fn id(n: usize) -> String {
	format!("00000000-0000-4000-8000-{n:012x}")
}
fn issue(n: usize) -> Command {
	Command::Issue {
		id: id(n),
		rights: Rights::Interact,
		label: " Phone ".into(),
		history: false,
	}
}

pub(super) fn ready<F: core::future::Future>(future: F) -> F::Output {
	let mut future = core::pin::pin!(future);
	let mut cx = core::task::Context::from_waker(core::task::Waker::noop());
	match future.as_mut().poll(&mut cx) {
		core::task::Poll::Ready(value) => value,
		core::task::Poll::Pending => panic!("test store unexpectedly blocked"),
	}
}

pub(super) struct MemoryStore<'a>(pub(super) &'a mut Vec<u8>);
impl GrantStorage for MemoryStore<'_> {
	type Error = &'static str;
	async fn replace(&mut self, bytes: Vec<u8>) -> Result<(), WriteFailure<Self::Error>> {
		*self.0 = bytes;
		Ok(())
	}
}

fn refusal(ledger: &mut GrantLedger, command: Command, want: Error) {
	let mut untouched = Vec::new();
	assert_eq!(
		ready(ledger.apply(&mut MemoryStore(&mut untouched), command)),
		Err(ApplyError::Policy(want))
	);
	assert!(untouched.is_empty());
}

fn apply(ledger: &mut GrantLedger, disk: &mut Vec<u8>, command: Command) -> Change {
	ready(ledger.apply(&mut MemoryStore(disk), command)).unwrap()
}

pub fn run() {
	live_policy_transactions();
	transactions();
	policy_and_restart();
	limits();
	documents();
	derivation();
	lossless_text();
	issuance_order();
}

fn live_policy_transactions() {
	use rooms_application::grants::GrantState;
	let mut state = GrantState::default();
	state
		.install(GrantLedger::restore(include_bytes!("../fixtures/grants-v1.json")).unwrap())
		.unwrap();
	let held = state.policy(&id(1)).unwrap();
	let prepared = state.prepare(Command::Revoke { id: id(1) }).unwrap();
	assert_eq!(held.read(|g| g.access()).unwrap(), Access::Interact);
	assert!(matches!(state.prepare(issue(2)), Err(Error::Busy)));
	assert!(matches!(state.clear(), Err(Error::Busy)));
	drop(prepared); // No storage was started, so existing policy stays usable.
	assert_eq!(held.read(|g| g.access()).unwrap(), Access::Interact);
	let mut disk = Vec::new();
	let prepared = state.prepare(Command::Revoke { id: id(1) }).unwrap();
	let written = ready(prepared.persist(&mut MemoryStore(&mut disk))).unwrap();
	assert_eq!(held.read(|g| g.access()).unwrap(), Access::Interact);
	state.commit(written).unwrap();
	assert_eq!(held.read(|g| g.access()), Err(Error::Revoked));
	state
		.install(GrantLedger::restore(include_bytes!("../fixtures/grants-v1.json")).unwrap())
		.unwrap();
	let prepared = state.prepare(Command::Revoke { id: id(1) }).unwrap();
	let written = ready(prepared.persist(&mut MemoryStore(&mut disk))).unwrap();
	let mut other = GrantLedger::default();
	assert_eq!(written.commit(&mut other), Err(Error::WrongOwner));
	assert_eq!(other.active_count().unwrap(), 0);
	assert_eq!(held.read(|g| g.access()), Err(Error::RecoveryRequired));
	state.install(GrantLedger::restore(&disk).unwrap()).unwrap();
	assert_eq!(held.read(|g| g.access()), Err(Error::Revoked));
	// A read callback cannot reenter a mutation or clear the ledger it borrows.
	state
		.install(GrantLedger::restore(include_bytes!("../fixtures/grants-v1.json")).unwrap())
		.unwrap();
	assert_eq!(held.read(|_| state.clear()).unwrap(), Err(Error::Busy));
	drop(state);
	assert_eq!(held.read(|g| g.access()), Err(Error::Revoked));
}

fn issuance_order() {
	let mut ledger = GrantLedger::default();
	let mut disk = ledger.document().unwrap();
	for n in [4, 1, 3] {
		apply(&mut ledger, &mut disk, issue(n));
	}
	apply(
		&mut ledger,
		&mut disk,
		Command::SetPolicy {
			id: id(4),
			patch: PolicyPatch {
				history: Some(true),
				..Default::default()
			},
		},
	);
	apply(&mut ledger, &mut disk, Command::Revoke { id: id(1) });
	let reopened = GrantLedger::restore(&disk).unwrap();
	let document: serde_json::Value = serde_json::from_slice(&reopened.document().unwrap()).unwrap();
	let ids: Vec<_> = document["grants"]
		.as_array()
		.unwrap()
		.iter()
		.map(|row| row["id"].as_str().unwrap())
		.collect();
	assert_eq!(ids, [id(4), id(1), id(3)]);
}

fn lossless_text() {
	use rooms_application::text::DocumentText;
	// Exercise every UTF-16 code unit, including paired and isolated
	// surrogates. This is a serialization contract, not lossy display text.
	let units: Vec<u16> = (0..=u16::MAX).collect();
	let text = DocumentText::from_utf16(&units);
	let encoded = serde_json::to_vec(&text).unwrap();
	let decoded: DocumentText = serde_json::from_slice(&encoded).unwrap();
	assert_eq!(decoded.utf16().collect::<Vec<_>>(), units);
	for invalid in [b"[]".as_slice(), b"null", b"42", b"{}"] {
		assert!(serde_json::from_slice::<DocumentText>(invalid).is_err());
	}
	let ledger = GrantLedger::restore(include_bytes!("../fixtures/grants-surrogate-v1.json")).unwrap();
	assert_eq!(
		ledger.get(&id(3)).unwrap().unwrap().label().utf16().collect::<Vec<_>>(),
		[0xd800]
	);
	let restored = GrantLedger::restore(&ledger.document().unwrap()).unwrap();
	assert_eq!(
		restored
			.get(&id(3))
			.unwrap()
			.unwrap()
			.label()
			.utf16()
			.collect::<Vec<_>>(),
		[0xd800]
	);
}

fn transactions() {
	struct FailedStore;
	impl GrantStorage for FailedStore {
		type Error = &'static str;
		async fn replace(&mut self, _: Vec<u8>) -> Result<(), WriteFailure<Self::Error>> {
			Err(WriteFailure::Unchanged("injected failure"))
		}
	}
	struct InterruptedStore<'a>(&'a mut Vec<u8>);
	impl GrantStorage for InterruptedStore<'_> {
		type Error = &'static str;
		async fn replace(&mut self, bytes: Vec<u8>) -> Result<(), WriteFailure<Self::Error>> {
			*self.0 = bytes;
			core::future::pending().await
		}
	}
	struct UncertainStore;
	impl GrantStorage for UncertainStore {
		type Error = &'static str;
		async fn replace(&mut self, _: Vec<u8>) -> Result<(), WriteFailure<Self::Error>> {
			Err(WriteFailure::Indeterminate("acknowledgement lost"))
		}
	}
	let mut ledger = GrantLedger::default();
	let mut disk = ledger.document().unwrap();
	let original = disk.clone();
	assert_eq!(
		ready(ledger.apply(&mut FailedStore, issue(1))),
		Err(ApplyError::Storage(WriteFailure::Unchanged("injected failure")))
	);
	assert!(!ledger.needs_recovery());
	assert_eq!(ledger.lifetime_count().unwrap(), 0);
	assert_eq!(disk, original);
	assert_eq!(apply(&mut ledger, &mut disk, issue(1)), Change::Issued);
	// Idempotent retry must not write even when storage would fail.
	assert_eq!(ready(ledger.apply(&mut FailedStore, issue(1))), Ok(Change::Unchanged));
	refusal(
		&mut ledger,
		Command::Issue {
			id: id(1),
			rights: Rights::Admin,
			label: " Phone ".into(),
			history: false,
		},
		Error::Conflict,
	);
	{
		let mut store = InterruptedStore(&mut disk);
		let mut future = core::pin::pin!(ledger.apply(&mut store, Command::Revoke { id: id(1) }));
		let mut cx = core::task::Context::from_waker(core::task::Waker::noop());
		assert!(core::future::Future::poll(future.as_mut(), &mut cx).is_pending());
		// Drop after storage changed, before its acknowledgement was observed.
	}
	assert!(ledger.needs_recovery());
	assert_eq!(ledger.get(&id(1)), Err(Error::RecoveryRequired));
	assert_eq!(ledger.document(), Err(Error::RecoveryRequired));
	refusal(&mut ledger, issue(2), Error::RecoveryRequired);
	let mut reopened = GrantLedger::restore(&disk).unwrap();
	assert_eq!(reopened.get(&id(1)).unwrap().unwrap().access(), Access::None);
	refusal(&mut reopened, issue(1), Error::Revoked);
	assert_eq!(
		ready(reopened.apply(&mut UncertainStore, issue(2))),
		Err(ApplyError::Storage(WriteFailure::Indeterminate("acknowledgement lost")))
	);
	assert!(reopened.needs_recovery());
	assert_eq!(reopened.get(&id(2)), Err(Error::RecoveryRequired));
	refusal(&mut reopened, issue(2), Error::RecoveryRequired);
}

fn policy_and_restart() {
	let mut ledger = GrantLedger::default();
	let mut disk = ledger.document().unwrap();
	apply(&mut ledger, &mut disk, issue(1));
	let patch = PolicyPatch {
		suspended: Some(true),
		note: Some("Away".into()),
		..Default::default()
	};
	apply(&mut ledger, &mut disk, Command::SetPolicy { id: id(1), patch });
	let grant = ledger.get(&id(1)).unwrap().unwrap();
	assert_eq!(grant.access(), Access::None);
	assert_eq!(grant.rights(), Rights::Interact);
	assert_eq!(grant.note().as_str().unwrap(), "Away");
	let mut ledger = GrantLedger::restore(&disk).unwrap();
	assert_eq!(ledger.get(&id(1)).unwrap().unwrap().access(), Access::None);
	let patch = PolicyPatch {
		rights: Some(Rights::Observe),
		history: Some(true),
		..Default::default()
	};
	apply(&mut ledger, &mut disk, Command::SetPolicy { id: id(1), patch });
	assert!(ledger.get(&id(1)).unwrap().unwrap().history());
	assert_eq!(ledger.get(&id(1)).unwrap().unwrap().access(), Access::None);
	let patch = PolicyPatch {
		suspended: Some(false),
		note: Some("obsolete".into()),
		..Default::default()
	};
	apply(&mut ledger, &mut disk, Command::SetPolicy { id: id(1), patch });
	let grant = ledger.get(&id(1)).unwrap().unwrap();
	assert_eq!(grant.access(), Access::Observe);
	assert_eq!(grant.note().as_str().unwrap(), "");
	assert!(grant.history());
	assert_eq!(
		apply(&mut ledger, &mut disk, Command::Revoke { id: id(1) }),
		Change::Revoked
	);
	assert_eq!(
		apply(&mut ledger, &mut disk, Command::Revoke { id: id(1) }),
		Change::Unchanged
	);
	assert_eq!(ledger.active_count().unwrap(), 0);
	assert_eq!(ledger.lifetime_count().unwrap(), 1);
	refusal(
		&mut ledger,
		Command::SetPolicy {
			id: id(1),
			patch: PolicyPatch::default(),
		},
		Error::Revoked,
	);
	refusal(
		&mut ledger,
		Command::SetPolicy {
			id: id(2),
			patch: PolicyPatch::default(),
		},
		Error::Missing,
	);
}

fn limits() {
	let mut ledger = GrantLedger::default();
	let mut disk = ledger.document().unwrap();
	for n in 0..MAX_ACTIVE_GRANTS {
		apply(&mut ledger, &mut disk, issue(n));
	}
	refusal(&mut ledger, issue(MAX_ACTIVE_GRANTS), Error::ActiveLimit);
	for n in 0..MAX_ACTIVE_GRANTS {
		apply(&mut ledger, &mut disk, Command::Revoke { id: id(n) });
	}
	for n in MAX_ACTIVE_GRANTS..MAX_LIFETIME_GRANTS {
		apply(&mut ledger, &mut disk, issue(n));
		apply(&mut ledger, &mut disk, Command::Revoke { id: id(n) });
	}
	let mut ledger = GrantLedger::restore(&disk).unwrap();
	refusal(&mut ledger, issue(MAX_LIFETIME_GRANTS), Error::LifetimeLimit);
	assert_eq!(ledger.active_count().unwrap(), 0);
	assert_eq!(ledger.lifetime_count().unwrap(), MAX_LIFETIME_GRANTS);
}

fn documents() {
	let record = json!({ "id": id(1), "label": " Phone ", "rights": "interact",
		"history": false, "suspended": false, "note": "", "revoked": false });
	// Written by the shared grant contract, not reconstructed from
	// the Rust serializer. They independently pin the current document contract.
	let bytes = include_bytes!("../fixtures/grants-v1.json");
	let fixture: serde_json::Value = serde_json::from_slice(bytes).unwrap();
	let ledger = GrantLedger::restore(bytes).unwrap();
	assert_eq!(
		ledger.get(&id(1)).unwrap().unwrap().label().as_str().unwrap(),
		" Phone "
	);
	assert_eq!(
		serde_json::from_slice::<serde_json::Value>(&ledger.document().unwrap()).unwrap(),
		fixture
	);
	let restored = GrantLedger::restore(include_bytes!("../fixtures/grants-suspended-v1.json")).unwrap();
	assert_eq!(restored.get(&id(1)).unwrap().unwrap().access(), Access::None);
	assert_eq!(restored.get(&id(1)).unwrap().unwrap().note().as_str().unwrap(), "Away");
	assert!(restored.get(&id(2)).unwrap().unwrap().revoked());
	assert_eq!(restored.active_count(), Ok(1));
	assert_eq!(restored.lifetime_count(), Ok(2));
	for invalid in [
		b"".as_slice(),
		b"null",
		b"\xff",
		b"{",
		b"{\"version\":1,\"grants\":[],\"extra\":0}",
	] {
		assert!(GrantLedger::restore(invalid).is_err());
	}
	assert!(matches!(
		GrantLedger::restore(&vec![b' '; MAX_DOCUMENT_BYTES + 1]),
		Err(Error::DocumentTooLarge)
	));
	let mut invalid = fixture.clone();
	invalid["version"] = json!(2);
	assert!(matches!(
		GrantLedger::restore(&serde_json::to_vec(&invalid).unwrap()),
		Err(Error::UnsupportedVersion)
	));
	invalid = fixture.clone();
	invalid["grants"] = json!([record.clone(), record.clone()]);
	assert!(matches!(
		GrantLedger::restore(&serde_json::to_vec(&invalid).unwrap()),
		Err(Error::DuplicateId)
	));
	for label in ["", "\u{feff}", &"😀".repeat(41)] {
		let mut invalid = fixture.clone();
		invalid["grants"][0]["label"] = json!(label);
		assert!(matches!(
			GrantLedger::restore(&serde_json::to_vec(&invalid).unwrap()),
			Err(Error::InvalidGrant)
		));
	}
	for label in ["\u{0085}", &"😀".repeat(40)] {
		let mut valid = fixture.clone();
		valid["grants"][0]["label"] = json!(label);
		assert!(GrantLedger::restore(&serde_json::to_vec(&valid).unwrap()).is_ok());
	}
	for bad_id in [
		id(1).to_uppercase().replace('4', "5"),
		"00000000-0000-4000-c000-000000000001".into(),
		"x".into(),
	] {
		let mut invalid = fixture.clone();
		invalid["grants"][0]["id"] = json!(bad_id);
		assert!(matches!(
			GrantLedger::restore(&serde_json::to_vec(&invalid).unwrap()),
			Err(Error::InvalidGrant)
		));
	}
}

fn derivation() {
	// HMAC-SHA256 vector independently computed over the shared
	// derivation's exact bytes and 16-byte truncation.
	let expected = [
		0x98, 0x09, 0x15, 0x85, 0x94, 0xad, 0xa3, 0x8d, 0xa4, 0x1f, 0x23, 0xb2, 0x0c, 0x34, 0xdb, 0xb7,
	];
	assert_eq!(derive_entropy(&[0x5a; 16], &id(1)).unwrap(), expected);
	assert_ne!(derive_entropy(&[0x5a; 16], &id(2)).unwrap(), expected);
	assert_ne!(derive_entropy(&[0x5b; 16], &id(1)).unwrap(), expected);
	assert_eq!(derive_entropy(&[0x5a; 16], "invalid"), Err(Error::InvalidGrant));
}
