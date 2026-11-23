//! Adopt what a committed command returned before reporting usable
//! authority: a send's exact live line occurrence, or the route a
//! `startDirect` introduced. The saved acquisition owns recovery. Replay never
//! remints a destination. The plans are the shared `adopt_line` and
//! `adopt_direct`, which attached views also use. A route to a member an open
//! conversation already reaches is given back.
use super::{Failure, Options, Value, json};
use rooms_application::content::session::{
	custody::FieldKey,
	results,
	workspace::{Adoption, DirectRefusal, Intent, LineReceipt, adopt_direct, adopt_line},
};
use rooms_application::failure::Retry;

fn intent(workspace: &Value) -> Result<Intent, Failure> {
	Intent::decode(&workspace.to_string()).map_err(|_| Failure::invalid("session returned an invalid workspace"))
}
/// A key no held custody uses, from platform entropy.
fn fresh<K>() -> Result<FieldKey<K>, Failure> {
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
	let Some(adoption) = Adoption::of(name, args) else {
		return Ok(());
	};
	if submitted["adopted"] == true {
		return Ok(());
	}
	if !submitted["result"].is_object() {
		return Ok(());
	}
	let before = intent(&original["workspace"])?;
	super::super::acquisition::at_current(options, async |status, base| {
		plan(&before, status, base, submitted, name, args, adoption)
	})
	.await
}
/// The acquisition that adopts this result against `status`, or none when the
/// result names nothing to adopt.
fn plan(
	before: &Intent,
	status: &Value,
	base: u64,
	submitted: &Value,
	name: &str,
	args: &[String],
	adoption: Adoption<'_>,
) -> Result<Option<Value>, Failure> {
	let result = &submitted["result"];
	let current = intent(&status["workspace"])?;
	let (mappings, releases, planned, source) = match adoption {
		Adoption::Line(target) => {
			let Some(receipt) = LineReceipt::read(&result.to_string())
				.map_err(|_| Failure::invalid("the command returned an invalid line receipt"))?
			else {
				return Ok(None);
			};
			let plan = adopt_line(before, &current, target, &receipt, fresh()?).map_err(Failure::invalid)?;
			(plan.mappings, plan.releases, plan.intent, None)
		}
		Adoption::Direct(start) => {
			let receipt = serde_json::from_value::<results::Direct>(result.clone())
				.map_err(|_| Failure::uncertain("peer has not supplied a direct inbox"))?;
			let operation = submitted["operation"]
				.as_str()
				.ok_or_else(|| Failure::invalid("session returned no operation"))?;
			let plan = match adopt_direct(before, &current, operation, &start, &receipt, fresh()?, fresh()?) {
				Ok(plan) => plan,
				Err(DirectRefusal::Open(_)) => {
					return Ok(Some(json!({"kind":"release-result", "operation":operation,
						"command_base":submitted["base"], "name":name, "args":args})));
				}
				Err(refusal) => return Err(Failure::invalid(refusal)),
			};
			(plan.mappings, Vec::new(), plan.intent, Some(plan.source))
		}
	};
	Ok(Some(json!({
		"kind":"result", "operation":submitted["operation"], "command_base":submitted["base"],
		"name":name, "args":args, "base":base,
		"mappings":mappings, "releases":releases, "intent":planned, "source":source,
	})))
}
