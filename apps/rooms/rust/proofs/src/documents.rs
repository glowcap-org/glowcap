use rooms_application::{
	documents::{DocumentError, SessionDocument},
	grants::GrantLedger,
};

pub fn run() {
	let fixture: serde_json::Value = serde_json::from_str(include_str!("../fixtures/session-documents.json")).unwrap();
	for document in [SessionDocument::Grants, SessionDocument::BridgeSecrets] {
		assert_eq!(
			fixture["ceilings"][document.key()].as_u64().unwrap(),
			document.max_bytes() as u64
		);
	}
	for row in fixture["decoded"].as_array().unwrap() {
		let input: Vec<u8> = row["input"]
			.as_array()
			.unwrap()
			.iter()
			.map(|b| b.as_u64().unwrap() as u8)
			.collect();
		assert_eq!(SessionDocument::Grants.decode(&input).ok(), row["text"].as_str());
	}
	assert_eq!(
		SessionDocument::Grants.decode(&vec![b'x'; SessionDocument::Grants.max_bytes() + 1]),
		Err(DocumentError::TooLarge)
	);
	let mut bom = b"\xef\xbb\xbf".to_vec();
	bom.extend_from_slice(include_bytes!("../fixtures/grants-v1.json"));
	assert_eq!(
		GrantLedger::restore(&bom)
			.unwrap()
			.records()
			.unwrap()
			.filter(|g| !g.revoked())
			.count(),
		1
	);
	bom.splice(..0, b"\xef\xbb\xbf".iter().copied());
	assert!(GrantLedger::restore(&bom).is_err());
}
