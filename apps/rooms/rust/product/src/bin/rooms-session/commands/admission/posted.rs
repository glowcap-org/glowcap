//! Adopt a send's exact live line occurrence before reporting usable authority.
//! The saved acquisition owns recovery; replay never remints a destination.
use super::{Failure, Options, Value, json, request};

pub(super) async fn acquire(
	options: &Options,
	original: &Value,
	submitted: &Value,
	name: &str,
	args: &[String],
) -> Result<(), Failure> {
	if !matches!(name, "say" | "sendFiles" | "refileLine") || submitted["adopted"] == true {
		return Ok(());
	}
	let result = &submitted["result"];
	if result["line"].is_null() || result["id"].is_null() {
		return Ok(());
	}
	let target = args
		.first()
		.ok_or_else(|| Failure::invalid("line receipt lacks its conversation"))?;
	let status = request(&options.state, json!({"verb":"status"})).await?;
	let mut intent = status["workspace"].clone();
	let row = intent["conversations"]
		.as_array_mut()
		.and_then(|rows| rows.iter_mut().find(|row| row["id"] == *target))
		.ok_or_else(|| Failure::invalid("the initiating conversation was removed; retain its receipt"))?;
	let prior = original["workspace"]["conversations"]
		.as_array()
		.and_then(|rows| rows.iter().find(|row| row["id"] == *target))
		.ok_or_else(|| Failure::invalid("the original conversation is unavailable"))?;
	for field in [
		"kind",
		"directory",
		"source",
		"access",
		"accepted",
		"publicEntry",
		"publication",
		"control",
		"moderator",
		"seat",
		"peer",
		"introduction",
		"closed",
	] {
		if row[field] != prior[field] {
			return Err(Failure::invalid(
				"the initiating conversation authority changed; retain its receipt",
			));
		}
	}
	let previous = |row: &Value| {
		row["lines"]
			.as_array()
			.and_then(|lines| lines.iter().find(|line| line["id"] == result["id"]))
			.map(|line| line["handle"].clone())
	};
	// Direct send settlement can already install its sender occurrence. The
	// candidate revision fences replacement of that exact current field.
	let replaced = previous(row);
	let preserved = if row["kind"] == "direct" {
		replaced.clone()
	} else {
		None
	};
	let destination = match &preserved {
		Some(key) => key.clone(),
		None => json!(super::super::operation()?),
	};
	let mut lines = row["lines"].as_array().cloned().unwrap_or_default();
	lines.retain(|line| line["id"] != result["id"]);
	lines.push(json!({"id":result["id"],"handle":destination}));
	row["lines"] = json!(lines);
	let base = status["revision"]
		.as_str()
		.and_then(|base| base.parse::<u64>().ok())
		.ok_or_else(|| Failure::invalid("session returned no workspace revision"))?;
	let releases: Vec<Value> = replaced
		.filter(|_| preserved.is_none())
		.into_iter()
		.map(|key| json!({"role":"line","key":key}))
		.collect();
	super::super::acquisition::submit(
		options,
		json!({
			"kind":"result", "operation":submitted["operation"], "command_base":submitted["base"],
			"name":name, "args":args, "base":base,
			"mappings":[[{"role":"line","key":result["line"]},{"role":"line","key":destination}]],
			"releases":releases, "intent":intent, "source":null,
		}),
	)
	.await
}
