use super::arguments::from_fixture;
use rooms_application::{
	bridge::{self, Answers, Form},
	text::DocumentText,
};
use serde_json::{Value, json};

pub fn run() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/bridge-client.json")).unwrap();
	for row in fixture["forms"].as_array().unwrap() {
		let parsed = Form::decode(row["raw"].as_str().unwrap());
		assert_eq!(parsed.is_ok(), row["accepted"].as_bool().unwrap(), "{}", row["name"]);
		if let Ok(form) = parsed {
			assert_eq!(form.has_secret(), row["hasSecret"].as_bool().unwrap());
			assert_eq!(Form::decode(&form.encode().unwrap()).unwrap(), form);
		}
	}
	for row in fixture["submissions"].as_array().unwrap() {
		let form = Form::decode(row["raw"].as_str().unwrap()).unwrap();
		let typed = Answers::decode(row["typed"].as_str().unwrap()).unwrap();
		let toggles: Vec<_> = row["toggles"]
			.as_array()
			.unwrap()
			.iter()
			.map(|v| v.as_str().unwrap())
			.collect();
		match form.submission(row["action"].as_str().unwrap(), &typed, &toggles) {
			Ok(submission) => {
				let result = json!({"answers": submission.answers(), "secrets": submission.secrets()});
				assert_eq!(result, row["result"], "{}", row["name"]);
			}
			Err(error) => assert_eq!(
				error.to_string(),
				row["result"]["why"].as_str().unwrap(),
				"{}",
				row["name"]
			),
		}
	}
	let form = Form::decode(fixture["forms"][0]["raw"].as_str().unwrap()).unwrap();
	// Structural form objects are strict: reject duplicate declarations instead
	// of selecting one. Answer maps retain their existing last-value behavior.
	let repeated = fixture["forms"][0]["raw"].as_str().unwrap().replacen(
		"\"title\":\"Identity\"",
		"\"title\":\"First\",\"title\":\"Identity\"",
		1,
	);
	assert!(matches!(Form::decode(&repeated), Err(bridge::Error::Form)));
	let split = form.split(Answers::decode(fixture["splitTyped"].as_str().unwrap()).unwrap());
	assert_eq!(
		json!({"answers":split.answers(),"secrets":split.secrets()}),
		fixture["split"]
	);
	assert!(matches!(
		form.submission("absent", &Answers::default(), &[]),
		Err(bridge::Error::Action)
	));
	for row in fixture["answers"].as_array().unwrap() {
		let answers = Answers::decode(row["raw"].as_str().unwrap());
		assert_eq!(answers.is_err(), row["error"] == true, "{}", row["raw"]);
		if let Ok(answers) = answers {
			assert_eq!(answers.encode().unwrap(), row["result"].as_str().unwrap());
		}
	}
	for row in fixture["wire"].as_array().unwrap() {
		let result = bridge::read_form(&from_fixture(&row["input"]));
		assert_eq!(result.is_err(), row["error"] == true);
		if let Ok(result) = result {
			assert_eq!(serde_json::to_value(result).unwrap(), row["result"]);
		}
	}
	let mut answers = Answers::default();
	for index in 0..16 {
		answers.insert(format!("a{index}"), "x".into()).unwrap();
	}
	assert!(answers.insert("extra".into(), "x".into()).is_err());
	answers.insert("a0".into(), "replacement".into()).unwrap();
	assert_eq!(answers.iter().next().unwrap().1.as_str(), Some("replacement"));
	assert!(answers.insert("a0".into(), "x".repeat(513).into()).is_err());
	assert_eq!(answers.get("a0").unwrap().as_str(), Some("replacement"));
	// Encoded controls can exceed the wire JSON bound even when every decoded
	// answer fits. Refuse the whole submission before executing its effect.
	for index in 0..16 {
		answers.insert(format!("a{index}"), "\0".repeat(512).into()).unwrap();
	}
	assert!(matches!(answers.encode(), Err(bridge::Error::Size)));
	assert!(matches!(
		Answers::decode(&" ".repeat(bridge::MAX_JSON + 1)),
		Err(bridge::Error::Size)
	));
	let surrogate = Answers::decode("{\"password\":\"\\ud800\"}").unwrap();
	assert_eq!(surrogate.get("password"), Some(&DocumentText::from_utf16(&[0xd800])));
}
