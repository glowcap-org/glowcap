use super::*;
use crate::room::{audience::Audience, mentions::Mentions};
use alloc::{vec, vec::Vec};
use serde_json::{Value, json};

fn form(body: &str) -> Value {
	json!({
		"text":body, "place":"room", "you":"Author", "away":false, "canPostFiles":true,
		"files":[], "keeping":false, "audience":["Renée","Reviewer"], "availableAudience":["reviewer","RENÉE"]
	})
}
fn plan(submission: Value) -> Value {
	serde_json::to_value(prepare(&serde_json::from_value(submission).unwrap())).unwrap()
}

#[test]
fn saved_room_audience_uses_the_mentions_read_by_every_member() {
	let line = plan(form("Read the `@literal` example."));
	let text = line["text"].as_str().unwrap();
	assert_eq!(text, "@Renée @Reviewer\n\nRead the `@literal` example.");
	for target in ["renée", "Reviewer"] {
		assert!(Mentions::of_line("Author", text, Some(target)).member);
	}
	assert!(!Mentions::of_line("Author", text, Some("literal")).member);
	for explicit in ["**@Other** replies", "@everyone replies"] {
		let mut turn = form(explicit);
		turn["availableAudience"] = json!([]);
		assert_eq!(plan(turn)["text"], explicit);
	}
	let mut files = form("");
	files["files"] = json!([{"name":"report.txt","mime":"text/plain","size":12}]);
	assert_eq!(plan(files.clone())["text"], "@Renée @Reviewer");
	files["text"] = json!("attached");
	assert_eq!(plan(files)["text"], "@Renée @Reviewer\n\nattached");
}

#[test]
fn audience_respects_scope_grammar_and_the_final_line_limit() {
	for (field, value) in [
		("place", json!("direct")),
		("editing", json!(true)),
		("keeping", json!(true)),
	] {
		let mut turn = form("Original");
		turn[field] = value;
		assert_eq!(plan(turn)["text"], "Original");
	}
	assert_eq!(plan(form("/me waves"))["text"], "/me waves");
	assert_eq!(plan(form("/help"))["kind"], "command");
	let mut missing = form("Continue");
	missing["availableAudience"] = json!(["Reviewer"]);
	assert!(plan(missing)["why"].as_str().unwrap().contains("Renée is offline"));
	let mut limited = form("ok");
	limited["lineLimit"] = json!("@Renée @Reviewer\n\nok".len() - 1);
	assert_eq!(plan(limited.clone())["kind"], "refused");
	limited["lineLimit"] = json!("@Renée @Reviewer\n\nok".len());
	assert_eq!(plan(limited)["kind"], "send");
	for names in [
		vec!["room"],
		vec!["a.b"],
		vec!["trailing-"],
		vec!["a b"],
		vec!["a", "A"],
	] {
		assert!(Audience::from_names(&names).is_none());
		assert!(serde_json::from_value::<Audience>(json!(names)).is_err());
	}
	let mut turn = form("Team report.");
	let names: Vec<_> = (0..32).map(|index| format!("member-{index}")).collect();
	turn["audience"] = json!(names);
	turn["availableAudience"] = json!(names);
	let line = plan(turn);
	let text = line["text"].as_str().unwrap();
	assert!(
		names
			.iter()
			.all(|name| Mentions::of_line("Author", text, Some(name)).member)
	);
	let too_many: Vec<_> = (0..33).map(|index| format!("member-{index}")).collect();
	assert!(serde_json::from_value::<Audience>(json!(too_many)).is_err());
}
