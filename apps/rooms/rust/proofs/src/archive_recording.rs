//! The recording policy replayed from `fixtures/archive-recording.json` on
//! the host and Wasm: which messages become records, and their standings.
use rooms_application::{
	archive::{
		Body, ConversationKind, Record,
		recording::{self, Message, Standings},
	},
	files::FileDescription,
	room::message::{ChangeKind, LineId},
	text::DocumentText,
};
use serde_json::Value;
fn message(input: &Value) -> Result<Option<Record>, rooms_application::archive::Error> {
	let source = "source".into();
	let generation: Option<DocumentText> = input["generation"].as_str().map(Into::into);
	let directory = input["directory"].as_str().unwrap().into();
	let conversation = input["conversation"].as_str().unwrap().into();
	let files: Vec<_> = input["files"]
		.as_array()
		.unwrap()
		.iter()
		.map(|file| {
			FileDescription::new(
				file["name"].as_str().unwrap().into(),
				file["mime"].as_str().unwrap().into(),
				file["size"].as_u64().unwrap(),
				file["width"].as_u64().unwrap(),
				file["height"].as_u64().unwrap(),
			)
			.unwrap()
		})
		.collect();
	recording::message(
		&source,
		&Message {
			keep: input["keep"].as_bool().unwrap(),
			generation: generation.as_ref(),
			kind: if input["kind"] == "room" {
				ConversationKind::Room
			} else {
				ConversationKind::Direct
			},
			directory: &directory,
			conversation: &conversation,
			nick: input["nick"].as_str().unwrap(),
			from: input["from"].as_str().unwrap(),
			text: input["text"].as_str().unwrap(),
			previews: &Default::default(),
			system: input["system"].as_bool().unwrap(),
			line: input["line"].as_u64().and_then(LineId::new),
			change: match input["change"].as_str().unwrap() {
				"said" => ChangeKind::Said,
				"edited" => ChangeKind::Edited,
				"refiled" => ChangeKind::Refiled,
				"withdrawn" => ChangeKind::Withdrawn,
				_ => unreachable!(),
			},
			at: input["at"].as_u64().unwrap(),
		},
		files.iter(),
	)
}
pub fn run() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/archive-recording.json")).unwrap();
	for case in fixture["cases"].as_array().unwrap() {
		let mut standings = Standings::default();
		let mut records = Vec::new();
		let mut coordinates = Vec::new();
		for input in case["inputs"].as_array().unwrap() {
			let admitted = message(input).unwrap();
			let Some(line) = admitted else {
				coordinates.push(Value::Null);
				continue;
			};
			let c = line.coordinates();
			coordinates.push(serde_json::json!({"source":c.source,"generation":c.generation,"id":c.id}));
			let standing = standings.prepare(&line, input["nick"].as_str().unwrap()).unwrap();
			records.push(line);
			if let Some(standing) = standing {
				records.push(standing.clone());
				standings.remember(standing).unwrap();
			}
		}
		let expected: Vec<Record> = serde_json::from_str(&case["records"].to_string()).unwrap();
		assert_eq!(records, expected, "{}", case["name"]);
		assert_eq!(
			coordinates,
			*case["coordinates"].as_array().unwrap(),
			"{}",
			case["name"]
		);
	}
	let input = &fixture["cases"][0]["inputs"][0];
	let mut longest = input.clone();
	longest["conversation"] = "r".repeat(rooms_application::archive::MAX_CONVERSATION_BYTES).into();
	let longest = message(&longest)
		.expect("every admitted workspace identity fits the archive")
		.unwrap();
	let encoded = serde_json::to_string(&longest).unwrap();
	assert_eq!(serde_json::from_str::<Record>(&encoded).unwrap(), longest);
	let mut multilingual = input.clone();
	let identity = "界".repeat(rooms_application::content::session::workspace::MAX_ID_UNITS);
	assert!(rooms_application::content::session::workspace::Id::new(identity.clone().into()).is_some());
	multilingual["conversation"] = identity.into();
	let multilingual = message(&multilingual)
		.expect("the maximum UTF-8 expansion fits recording")
		.unwrap();
	assert_eq!(
		serde_json::from_str::<Record>(&serde_json::to_string(&multilingual).unwrap()).unwrap(),
		multilingual
	);
	for (field, value) in [
		("nick", serde_json::json!("everyone")),
		("from", serde_json::json!("everyone")),
		("generation", serde_json::json!("bad\u{0000}generation")),
		("directory", serde_json::json!("d".repeat(8193))),
		(
			"conversation",
			serde_json::json!("r".repeat(rooms_application::archive::MAX_CONVERSATION_BYTES + 1)),
		),
		(
			"text",
			serde_json::json!("t".repeat(rooms_application::room::line::MAX_LINE_BYTES + 1)),
		),
		("at", serde_json::json!(1_u64 << 53)),
	] {
		let mut invalid = input.clone();
		invalid[field] = value;
		assert!(message(&invalid).is_err(), "invalid {field} was retained");
		invalid["keep"] = false.into();
		assert!(
			message(&invalid).unwrap().is_none(),
			"transient input need not be retained"
		);
	}
	let mut withdrawal = input.clone();
	withdrawal["change"] = "withdrawn".into();
	withdrawal["text"] = "superseded contents".into();
	let withdrawn = message(&withdrawal).unwrap().unwrap();
	assert!(
		matches!(withdrawn.body(), Body::Line { text, attachments, .. } if text.as_str() == Some("") && attachments.is_empty())
	);

	let line = message(input).unwrap().unwrap();
	let mut memo = Standings::default();
	assert!(memo.prepare(&line, "alice").unwrap().is_some());
	assert!(
		memo.prepare(&line, "alice").unwrap().is_some(),
		"preparation is not commitment"
	);
	memo.remember(memo.prepare(&line, "alice").unwrap().unwrap()).unwrap();
	assert!(memo.prepare(&line, "bob").unwrap().is_none());
	assert!(
		Standings::default().prepare(&line, "alice").unwrap().is_some(),
		"another account needs its own standing"
	);
	for directory_size in [0, 8192] {
		let mut memo = Standings::default();
		let mut first = None;
		for i in 0..if directory_size == 0 { 129 } else { 40 } {
			let mut row = input.clone();
			row["conversation"] = format!("room-{i:03}").into();
			if directory_size != 0 {
				row["directory"] = "d".repeat(directory_size).into();
			}
			let line = message(&row).unwrap().unwrap();
			let standing = memo.prepare(&line, "alice").unwrap().unwrap();
			assert!(matches!(standing.body(), Body::Standing { .. }));
			memo.remember(standing).unwrap();
			if first.is_none() {
				first = Some(line);
			}
		}
		assert!(
			memo.prepare(&first.unwrap(), "alice").unwrap().is_some(),
			"memo capacity did not evict"
		);
	}
}
