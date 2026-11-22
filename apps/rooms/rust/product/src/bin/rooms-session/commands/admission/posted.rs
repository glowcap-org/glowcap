//! Adopt a send's exact live line occurrence before reporting usable authority.
//! The saved acquisition owns recovery. Replay never remints a destination.
//! The plan itself is the shared `adopt_line`, which attached views also use.
use super::{Failure, Options, Value, json, request};
use rooms_application::content::session::{
	custody::FieldKey,
	workspace::{Intent, LineReceipt, adopt_line, posted_conversation},
};
use rooms_application::failure::Retry;

fn intent(workspace: &Value) -> Result<Intent, Failure> {
	Intent::decode(&workspace.to_string()).map_err(|_| Failure::invalid("session returned an invalid workspace"))
}
fn destination() -> Result<
	rooms_application::content::session::custody::FieldKey<rooms_application::content::session::custody::Line>,
	Failure,
> {
	let mut entropy = [0; 16];
	rooms_platform::entropy::fill(&mut entropy)
		.map_err(|error| Failure::new("entropy", Retry::AfterStateChange, error))?;
	FieldKey::from_entropy(entropy)
		.ok_or_else(|| Failure::new("entropy", Retry::AfterStateChange, "entropy produced no key"))
}
pub(super) async fn acquire(
	options: &Options,
	original: &Value,
	submitted: &Value,
	name: &str,
	args: &[String],
) -> Result<(), Failure> {
	let Some(target) = posted_conversation(name, args) else {
		return Ok(());
	};
	if submitted["adopted"] == true {
		return Ok(());
	}
	let result = &submitted["result"];
	if !result.is_object() {
		return Ok(());
	}
	let Some(receipt) = LineReceipt::read(&result.to_string())
		.map_err(|_| Failure::invalid("the command returned an invalid line receipt"))?
	else {
		return Ok(());
	};
	let status = request(&options.state, json!({"verb":"status"})).await?;
	let plan = adopt_line(
		&intent(&original["workspace"])?,
		&intent(&status["workspace"])?,
		target,
		&receipt,
		destination()?,
	)
	.map_err(Failure::invalid)?;
	let base = status["revision"]
		.as_str()
		.and_then(|base| base.parse::<u64>().ok())
		.ok_or_else(|| Failure::invalid("session returned no workspace revision"))?;
	super::super::acquisition::submit(
		options,
		json!({
			"kind":"result", "operation":submitted["operation"], "command_base":submitted["base"],
			"name":name, "args":args, "base":base,
			"mappings":plan.mappings, "releases":plan.releases, "intent":plan.intent, "source":null,
		}),
	)
	.await
}
