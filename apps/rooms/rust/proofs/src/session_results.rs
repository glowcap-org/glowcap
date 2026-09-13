use rooms_application::{
	grants::Access,
	session::checkpoint::{
		Checkpoint, Routes,
		commands::results::{Command, Kind, Plan},
	},
};
use serde_json::Value;
mod recovery;

struct CapturedRoutes<'a>(&'a Value);
impl Routes for CapturedRoutes<'_> {
	fn locator_authority(&self, raw: &str) -> Option<String> {
		self.0["locatorAuthorities"][raw].as_str().map(str::to_owned)
	}
	fn sturdyref_authority(&self, raw: &str) -> Option<String> {
		self.0["sturdyrefAuthorities"][raw].as_str().map(str::to_owned)
	}
}
fn fixture() -> Value {
	serde_json::from_str(include_str!("../fixtures/session-results.json")).unwrap()
}
fn plan(plan: &Plan, expected: &Value, name: &Value) {
	assert_eq!(plan.kind().as_str(), expected["kind"].as_str().unwrap(), "{name} kind");
	assert_eq!(
		plan.intent().unwrap().as_str(),
		expected["intent"].as_str(),
		"{name} intent"
	);
	assert_eq!(
		plan.directory().as_str(),
		expected["directory"].as_str(),
		"{name} directory"
	);
	assert_eq!(
		plan.recovery_key().and_then(|v| v.as_str()),
		expected["recoveryKey"].as_str()
	);
	assert_eq!(
		plan.steward().and_then(|v| v.as_str()),
		expected["stewardLink"].as_str()
	);
	assert_eq!(
		plan.manager().and_then(|v| v.as_str()),
		expected["managerLink"].as_str()
	);
	if let Some(label) = expected["label"].as_str() {
		assert_eq!(plan.label().as_str(), Some(label));
	}
	if let Some(id) = expected["conversationId"].as_str() {
		assert_eq!(plan.conversation().as_str(), Some(id));
	}
	assert_eq!(
		plan.policy().map(|v| serde_json::to_value(v).unwrap()),
		expected.get("policy").cloned()
	);
}
fn check(fixture: &Value, routes: &impl Routes) {
	recovery::check(fixture, routes);
	for row in fixture["plans"].as_array().unwrap() {
		let current = Checkpoint::decode(row["before"].as_str().unwrap(), routes).unwrap();
		let args = serde_json::from_str::<Vec<_>>(row["args"].as_str().unwrap()).unwrap();
		let command: Result<Command, _> = serde_json::from_value(row["command"].clone());
		let result = command
			.ok()
			.map(|command| command.prepare(&current, &args, routes, row["allowExisting"].as_bool().unwrap()));
		assert_eq!(
			result.as_ref().is_some_and(Result::is_ok),
			row["result"].is_object(),
			"{} prepare: {:?}",
			row["name"],
			result.as_ref().and_then(|v| v.as_ref().err())
		);
		if let Some(Ok(actual)) = result {
			plan(&actual, &row["result"], &row["name"]);
		}
	}
	for row in fixture["applications"].as_array().unwrap() {
		let current = Checkpoint::decode(row["before"].as_str().unwrap(), routes).unwrap();
		let before = current.encode_for(Access::Admin).unwrap();
		let result = Kind::parse(row["kind"].as_str().unwrap()).map(|kind| {
			Plan::decode(kind, &row["intent"].as_str().unwrap().into(), routes)
				.and_then(|plan| plan.apply(&current, &row["result"].as_str().unwrap().into(), routes))
		});
		assert_eq!(
			result.as_ref().is_some_and(Result::is_ok),
			row["after"].is_string(),
			"{} apply: {:?}",
			row["name"],
			result.as_ref().and_then(|v| v.as_ref().err())
		);
		if let Some(Ok(after)) = result {
			assert_eq!(
				after.encode_for(Access::Admin).unwrap(),
				row["after"].as_str().unwrap(),
				"{} checkpoint",
				row["name"]
			);
		}
		assert_eq!(
			current.encode_for(Access::Admin).unwrap(),
			before,
			"result mutated its source"
		);
	}
	for row in fixture["resumptions"].as_array().unwrap() {
		let current = Checkpoint::decode(row["before"].as_str().unwrap(), routes).unwrap();
		let result = Kind::parse(row["kind"].as_str().unwrap()).map(|kind| {
			Plan::decode(kind, &row["intent"].as_str().unwrap().into(), routes)
				.and_then(|plan| plan.resume(&current, routes))
		});
		assert_eq!(
			result.as_ref().is_some_and(Result::is_ok),
			row["result"].is_object(),
			"{} resume: {:?}",
			row["name"],
			result.as_ref().and_then(|v| v.as_ref().err())
		);
		if let Some(Ok(actual)) = result {
			plan(&actual, &row["result"], &row["name"]);
		}
	}
}
pub fn run() {
	let fixture = fixture();
	check(&fixture, &CapturedRoutes(&fixture));
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[test]
fn result_plans_use_the_native_locator_parser() {
	check(&fixture(), &rooms_glowcap::routes::CheckpointRoutes);
}
