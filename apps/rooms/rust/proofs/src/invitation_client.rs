use super::arguments::from_fixture;
use rooms_application::room::{authority, invitation::Receipt, queries};
use serde_json::Value;

struct Reply<'a>(&'a Value);
impl authority::Reply for Reply<'_> {
	fn text(&self) -> Option<&str> {
		self.0.as_str()
	}
	fn list_len(&self) -> Option<usize> {
		self.0.as_array().map(Vec::len)
	}
	fn list_text(&self, index: usize) -> Option<&str> {
		self.0.as_array()?.get(index)?.as_str()
	}
}
pub fn run() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/room-invitation-client.json")).unwrap();
	for row in fixture["called"].as_array().unwrap() {
		assert_eq!(
			queries::called(&from_fixture(&row["input"])),
			row["result"].as_str().unwrap()
		);
	}
	for row in fixture["privacy"].as_array().unwrap() {
		assert_eq!(
			queries::is_private(&from_fixture(&row["input"])).ok(),
			row["result"].as_bool()
		);
	}
	for row in fixture["policies"].as_array().unwrap() {
		let result = queries::policy(&Reply(&row["input"]));
		assert_eq!(result.is_err(), row["error"] == true);
		if let Ok(policy) = result {
			assert_eq!(serde_json::to_value(policy).unwrap(), row["result"]);
		}
	}
	let bytes: [u8; 16] = serde_json::from_value(fixture["entropy"].clone()).unwrap();
	let receipt = Receipt::from_entropy(bytes);
	for call in fixture["calls"].as_array().unwrap() {
		if call["verb"] == "claimInvitation" {
			assert_eq!(receipt.as_str(), call["args"][0].as_str().unwrap());
		}
	}
	assert_eq!(Receipt::from_entropy([0; 16]).as_str(), "0".repeat(32));
	assert_eq!(Receipt::from_entropy([255; 16]).as_str(), "f".repeat(32));
}
