//! Captured TypeScript identities plus commitment and revocation invariants.
use rooms_application::{
	archive::{Filter, shares::*},
	documents::WriteFailure,
};
const ID: &str = "12345678-1234-4234-8234-123456789abc";
fn share(n: usize) -> Share {
	Share::new(
		format!("12345678-1234-4234-8234-{n:012x}"),
		"label".into(),
		Filter::default(),
	)
	.unwrap()
}
pub fn run() {
	use crate::{
		archive::Passables,
		arguments::{Arg, text},
	};
	use rooms_application::archive::{output, shares::protocol};
	let filter = output::filter::<Passables>(&Filter::default()).unwrap();
	let args = [text(ID), text("Garden"), filter];
	let args: Vec<_> = args.iter().collect();
	assert!(matches!(
		protocol::Request::read(protocol::ISSUE, &args).unwrap(),
		protocol::Request::Issue(_)
	));
	assert!(protocol::Request::read(protocol::LIST, &args).is_err());
	assert!(protocol::Request::read(protocol::ISSUE, &args[..2]).is_err());
	assert!(protocol::Request::read(protocol::REVOKE, &[&Arg::Integer(1)]).is_err());
	assert!(protocol::Request::read(protocol::ISSUE, &[&text(ID), &text(&"x".repeat(81)), &Arg::Null]).is_err());
	let fixture: serde_json::Value = serde_json::from_str(include_str!("../fixtures/archive-shares.json")).unwrap();
	let root: [u8; 16] = core::array::from_fn(|i| i as u8);
	for v in fixture["vectors"].as_array().unwrap() {
		let input = v["input"].as_str().unwrap();
		let mut ledger = Ledger::restore(input.as_bytes()).unwrap();
		assert_eq!(ledger.document().unwrap(), input.as_bytes());
		let row = ledger.get(ID).unwrap().unwrap().clone();
		assert_eq!(
			row.entropy(&root).to_vec(),
			v["entropy"]
				.as_array()
				.unwrap()
				.iter()
				.map(|n| n.as_u64().unwrap() as u8)
				.collect::<Vec<_>>()
		);
		assert_eq!(
			ledger
				.apply::<()>(Command::Issue(row.clone()), |_| panic!("retry must not rewrite"))
				.unwrap(),
			Change::Unchanged
		);
		assert_eq!(
			ledger
				.apply(Command::Revoke(ID.into()), |bytes| {
					assert_eq!(bytes, v["retired"].as_str().unwrap().as_bytes());
					Ok::<_, WriteFailure<()>>(())
				})
				.unwrap(),
			Change::Revoked
		);
		assert!(ledger.get(ID).unwrap().unwrap().revoked());
		assert_eq!(
			ledger.apply::<()>(Command::Issue(row), |_| panic!()),
			Err(ApplyError::Policy(Error::Revoked))
		);
		assert_eq!(
			ledger.apply::<()>(Command::Revoke(ID.into()), |_| panic!()).unwrap(),
			Change::Unchanged
		);
		assert!(
			Ledger::restore(input.replace("\"source\":null,", "").as_bytes()).is_err()
				|| !input.contains("\"source\":null,")
		);
		assert!(
			Ledger::restore(
				input
					.replace("\"revoked\":false", "\"revoked\":false,\"extra\":true")
					.as_bytes()
			)
			.is_err()
		);
	}
	let mut ledger = Ledger::default();
	assert_eq!(
		ledger.apply(Command::Issue(share(1)), |_| Err(WriteFailure::Unchanged("refused"))),
		Err(ApplyError::Storage(WriteFailure::Unchanged("refused")))
	);
	assert!(!ledger.needs_recovery());
	assert_eq!(ledger.records().unwrap().len(), 0);
	let mut disk = Vec::new();
	assert_eq!(
		ledger.apply(Command::Issue(share(1)), |bytes| {
			disk = bytes.to_vec();
			Err(WriteFailure::Indeterminate("sync"))
		}),
		Err(ApplyError::Storage(WriteFailure::Indeterminate("sync")))
	);
	assert!(ledger.needs_recovery());
	assert!(ledger.records().is_err());
	assert!(ledger.document().is_err());
	let restored = Ledger::restore(&disk).unwrap();
	assert_eq!(restored.records().unwrap().len(), 1);
	let mut ledger = Ledger::default();
	for n in 0..MAX_LIFETIME {
		ledger
			.apply(Command::Issue(share(n)), |_| Ok::<_, WriteFailure<()>>(()))
			.unwrap();
		ledger
			.apply(Command::Revoke(share(n).id().into()), |_| Ok::<_, WriteFailure<()>>(()))
			.unwrap();
	}
	assert_eq!(
		ledger.apply::<()>(Command::Issue(share(MAX_LIFETIME)), |_| panic!()),
		Err(ApplyError::Policy(Error::Limit))
	);
	let mut ledger = Ledger::default();
	for n in 0..MAX_ACTIVE {
		ledger
			.apply(Command::Issue(share(n)), |_| Ok::<_, WriteFailure<()>>(()))
			.unwrap();
	}
	assert_eq!(
		ledger.apply::<()>(Command::Issue(share(MAX_ACTIVE)), |_| panic!()),
		Err(ApplyError::Policy(Error::Limit))
	);
	let existing = ledger.records().unwrap().next().unwrap();
	let conflict = Share::new(existing.id().into(), "changed".into(), existing.filter().clone()).unwrap();
	assert_eq!(
		ledger.apply::<()>(Command::Issue(conflict), |_| panic!()),
		Err(ApplyError::Policy(Error::Conflict))
	);
}
