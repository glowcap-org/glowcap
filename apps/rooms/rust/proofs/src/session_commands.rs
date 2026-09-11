use rooms_application::{
	grants::Access,
	session::{
		checkpoint::{
			commands::{self, Command, CommandRoutes, Facts},
			Checkpoint, Routes,
		},
		state::Impact,
	},
	text::DocumentText,
};
use serde_json::Value;

struct CapturedRoutes<'a>(&'a Value);
impl Routes for CapturedRoutes<'_> {
	fn locator_authority(&self, raw: &str) -> Option<String> {
		self.0["locatorAuthorities"][raw].as_str().map(str::to_owned)
	}
	fn sturdyref_authority(&self, raw: &str) -> Option<String> {
		self.0["sturdyrefAuthorities"][raw].as_str().map(str::to_owned)
	}
}
impl CommandRoutes for CapturedRoutes<'_> {
	fn authority_token(&self, raw: &str) -> Option<String> {
		self.0["tokens"][raw].as_str().map(str::to_owned)
	}
}
struct CapturedFacts {
	publications: Vec<(DocumentText, DocumentText, DocumentText)>,
	scopes: Vec<(DocumentText, DocumentText)>,
}
impl CapturedFacts {
	fn new(value: &Value) -> Self {
		Self {
			publications: value["publications"]
				.as_object()
				.into_iter()
				.flatten()
				.flat_map(|(directory, names)| {
					names.as_object().unwrap().iter().map(|(name, generation)| {
						(
							directory.as_str().into(),
							name.as_str().into(),
							generation.as_str().unwrap().into(),
						)
					})
				})
				.collect(),
			scopes: value["scopes"]
				.as_object()
				.into_iter()
				.flatten()
				.map(|(id, scope)| (id.as_str().into(), scope.as_str().unwrap().into()))
				.collect(),
		}
	}
}
impl Facts for CapturedFacts {
	fn room_publication(&self, directory: &DocumentText, name: &DocumentText) -> Option<&DocumentText> {
		self.publications
			.iter()
			.find(|(d, n, _)| d == directory && n == name)
			.map(|(_, _, v)| v)
	}
	fn bridge_scope(&self, id: &DocumentText) -> Option<DocumentText> {
		self.scopes
			.iter()
			.find(|(held, _)| held == id)
			.map(|(_, value)| value.clone())
	}
}
fn fixture() -> Value {
	serde_json::from_str(include_str!("../fixtures/session-commands.json")).unwrap()
}
fn check(fixture: &Value, routes: &impl CommandRoutes) {
	let mut exercised = std::collections::BTreeSet::new();
	for row in fixture["rows"].as_array().unwrap() {
		let command: Command = serde_json::from_value(row["command"].clone()).unwrap();
		let args: Vec<DocumentText> = serde_json::from_str(row["args"].as_str().unwrap()).unwrap();
		let before = Checkpoint::decode(row["before"].as_str().unwrap(), routes).unwrap();
		let original = before.encode_for(Access::Admin).unwrap();
		let facts = CapturedFacts::new(&row["facts"]);
		let result = command.apply(&before, &args, routes, &facts);
		assert_eq!(
			result.is_ok(),
			row["after"].is_string(),
			"{}: {:?}",
			row["name"],
			result.as_ref().err()
		);
		if let Ok(after) = result {
			exercised.insert(row["command"].as_str().unwrap());
			assert_eq!(
				after.encode_for(Access::Admin).unwrap(),
				row["after"].as_str().unwrap(),
				"{}",
				row["name"]
			);
		}
		if let Some(expected) = row["material"].as_str() {
			assert_eq!(
				command.material(&args).unwrap().as_str(),
				Some(expected),
				"{} material",
				row["name"]
			);
		}
		assert_eq!(
			before.encode_for(Access::Admin).unwrap(),
			original,
			"command mutated its source"
		);
		let impact = match row["impact"].as_str().unwrap() {
			"presentation" => Impact::Presentation,
			"standing" => Impact::Standing,
			"realization" => Impact::Realization,
			_ => panic!("fixture impact"),
		};
		assert_eq!(command.impact(), impact);
	}
	assert_eq!(exercised.len(), 26, "every command needs a successful scenario");
	for row in fixture["offers"].as_array().unwrap() {
		let before = Checkpoint::decode(row["before"].as_str().unwrap(), routes).unwrap();
		let args: Vec<DocumentText> = serde_json::from_str(row["args"].as_str().unwrap()).unwrap();
		let result = commands::prepare_offer(&before, &args);
		assert_eq!(result.is_ok(), row["result"].is_object(), "{} offer", row["name"]);
		if let Ok(offer) = result {
			let expected = &row["result"];
			assert_eq!(offer.room.as_str(), expected["roomConversationId"].as_str());
			assert_eq!(offer.direct.as_str(), expected["directConversationId"].as_str());
			assert_eq!(offer.label.as_str(), expected["label"].as_str());
			assert_eq!(offer.link.and_then(DocumentText::as_str), expected["link"].as_str());
		}
	}
}
pub fn run() {
	let fixture = fixture();
	check(&fixture, &CapturedRoutes(&fixture));
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[test]
fn commands_use_the_native_locator_and_generation_parser() {
	let fixture = fixture();
	let routes = rooms_glowcap::routes::CheckpointRoutes;
	for (raw, token) in fixture["tokens"].as_object().unwrap() {
		assert_eq!(routes.authority_token(raw).as_deref(), token.as_str(), "{raw} token");
	}
	check(&fixture, &routes);
}
