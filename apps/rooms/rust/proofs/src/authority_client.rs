use rooms_application::room::authority;
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
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/room-authority-client.json")).unwrap();
	for row in fixture["identities"].as_array().unwrap() {
		assert_eq!(
			authority::room_identity(row["token"].as_str().unwrap()).ok().as_deref(),
			row["identity"].as_str()
		);
		let token = row["token"].as_str().unwrap();
		assert_eq!(
			authority::verify_steward(&Reply(&row["identity"]), token).is_ok(),
			!row["identity"].is_null()
		);
		assert!(authority::verify_steward(&Reply(&serde_json::json!("another room")), token).is_err());
		assert!(authority::verify_steward(&Reply(&Value::Null), token).is_err());
	}
	for row in fixture["managers"].as_array().unwrap() {
		assert_eq!(
			authority::verify_manager(&Reply(&row["governed"]), &Reply(&row["identity"])).is_ok(),
			row["accepted"].as_bool().unwrap()
		);
	}
	for row in fixture["policies"].as_array().unwrap() {
		let reply = Reply(&row["answer"]);
		let result = authority::policy_update(&reply);
		assert_eq!(result.is_ok(), !row["result"].is_null(), "{}", row["answer"]);
		if let Ok(result) = result {
			assert_eq!(result.name, row["result"]["name"].as_str().unwrap());
			assert_eq!(serde_json::to_value(result.policy).unwrap(), row["result"]["policy"]);
		}
	}
	for row in fixture["grants"].as_array().unwrap() {
		let reply = Reply(&row["answer"]);
		let accepted = authority::steward_grant(&reply)
			.is_ok_and(|grant| row["token"].as_str().is_some_and(|token| grant.verify(token).is_ok()));
		assert_eq!(accepted, row["accepted"].as_bool().unwrap(), "{}", row["answer"]);
	}
}
