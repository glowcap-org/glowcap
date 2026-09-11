use rooms_application::archive::identity::{Identity, MAX_BYTES};
pub fn run() {
	let identity = Identity::new([0xab; 32], [0x17; 16]);
	let expected = format!(
		"{{\"version\":1,\"identitySeed\":\"{}\",\"archiveEntropy\":\"{}\"}}\n",
		"ab".repeat(32),
		"17".repeat(16)
	);
	assert_eq!(identity.encode(), expected.as_bytes());
	let restored = Identity::decode(expected.as_bytes()).unwrap();
	assert_eq!(restored.seed(), identity.seed());
	assert_eq!(restored.entropy(), identity.entropy());
	assert!(Identity::decode(format!("\u{feff}{expected}").as_bytes()).is_ok());
	assert!(Identity::decode(expected.replace("\"version\":1", "\"version\":1e0").as_bytes()).is_ok());
	for invalid in [
		expected.replace("ab", "AB"),
		expected.replace(&"17".repeat(16), &"17".repeat(15)),
		expected.replace("\"version\":1", "\"version\":2"),
		expected.replace("\"version\":1", "\"extra\":true,\"version\":1"),
		"{}".into(),
	] {
		assert!(Identity::decode(invalid.as_bytes()).is_err());
	}
	assert!(Identity::decode(&vec![b' '; MAX_BYTES + 1]).is_err());
	assert!(Identity::decode(&[0xff]).is_err());
}
