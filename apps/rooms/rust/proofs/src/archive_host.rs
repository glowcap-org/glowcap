use crate::arguments::{from_fixture, text, Arg};
use rooms_application::archive::{
	request::{Issuance, Request},
	Access, Facet, Filter,
};
pub fn run() {
	let reason = format!("{}🙂", "a".repeat(4095));
	assert_eq!(rooms_application::failure::reason_prefix(&reason).len(), 4095);
	assert_eq!(rooms_application::failure::reason_prefix("short"), "short");
	let fixture: serde_json::Value = serde_json::from_str(include_str!("../fixtures/archive.json")).unwrap();
	let record = from_fixture(&fixture["records"][0]["input"]);
	let all = from_fixture(&fixture["filters"][0]["input"]);
	let root = Facet::new(Filter::default(), Access::ReadWrite).unwrap();
	assert!(matches!(root.admit("put", &[&record]).unwrap(), Request::Put(_)));
	let limit = Arg::Integer(i128::MAX);
	let after = Arg::Integer(42);
	assert!(matches!(
		root.admit("read", &[&all, &after, &limit]).unwrap(),
		Request::Read {
			after: 42,
			limit: 128,
			..
		}
	));
	assert!(root.admit("read", &[&all, &Arg::Float(42.0), &limit]).is_err());
	assert!(root.admit("read", &[&all, &after, &Arg::Integer(0)]).is_err());
	for verb in ["read", "put", "narrow", "unknown"] {
		assert!(root.admit::<&Arg>(verb, &[]).is_err());
	}
	let read = match root.admit("narrow", &[&all, &text("read")]).unwrap() {
		Request::Narrow(facet) => facet,
		_ => panic!("facet"),
	};
	assert!(read.admit("put", &[&record]).is_err());
	assert!(read.admit("narrow", &[&all, &text("read-write")]).is_err());
	let scoped = Facet::new(
		Filter {
			conversation: Some("other".into()),
			..Default::default()
		},
		Access::Read,
	)
	.unwrap();
	let asked = Arg::List(vec![
		Arg::Null,
		Arg::Null,
		Arg::Null,
		Arg::Null,
		Arg::Null,
		text("garden"),
		Arg::Null,
	]);
	let empty = scoped.admit("read", &[&asked, &after, &limit]).unwrap();
	assert!(matches!(empty,Request::Empty(page) if page.next==42 && !page.more && page.records.is_empty()));
	let mut issuer = Issuance::new();
	for _ in 0..256 {
		assert!(issuer.available());
		issuer.minted().unwrap();
	}
	assert!(!issuer.available());
	assert!(issuer.minted().is_err());
	assert!(Issuance::new().available());
}
