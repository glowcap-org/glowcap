//! New automatic gestures re-prepare only after proven absence and unchanged selection.
use super::{Failure, Options, operation, request};
use serde_json::{Value, json};
use std::time::Duration;
mod posted;
mod selection;
pub(super) use selection::same_directory_contact;

pub(super) async fn command(options: &Options, name: &str, args: Vec<String>) -> Result<Value, Failure> {
	let original = request(&options.state, json!({"verb":"status"})).await?;
	command_at(options, name, args, original).await
}
// The caller may already hold the selection snapshot. Keep it through initial
// admission and any proven-absent retry instead of silently selecting again.
pub(super) async fn command_at(
	options: &Options,
	name: &str,
	args: Vec<String>,
	original: Value,
) -> Result<Value, Failure> {
	let base = match options.get("base") {
		Some(_) => options.number("base", 0)?,
		None => original["revision"]
			.as_str()
			.and_then(|revision| revision.parse::<u64>().ok())
			.ok_or_else(|| Failure::invalid("session returned no workspace revision"))?,
	};
	let id = options
		.get("operation")
		.map(str::to_owned)
		.map(Ok)
		.unwrap_or_else(operation)?;
	let automatic = options.get("base").is_none() && options.get("operation").is_none();
	let mut base = base;
	let mut id = id;
	for attempt in 0..4 {
		let response = command_once(options, &id, base, name, &args).await?;
		if response["status"] != "conflict" {
			posted::acquire(options, &original, &response, name, &args)
				.await
				.map_err(|mut error| {
					error.message = format!(
						"operation {}, base {base} committed; result acquisition failed: {}; retain the original request",
						response["operation"].as_str().unwrap_or(&id),
						error.message
					);
					error
				})?;
			return Ok(response);
		}
		// Only a terminal, known-absent admission permits another operation.
		// Fence the original selected rows, including authority, membership and
		// user edits. Unrelated supervisor and receipt writes may advance base.
		if !automatic || attempt == 3 {
			return Err(Failure::invalid("workspace revision changed; command was not admitted"));
		}
		let current = request(&options.state, json!({"verb":"status"})).await?;
		if !selection::unchanged(name, &args, &original["workspace"], &current["workspace"]) {
			return Err(Failure::invalid(
				"workspace selection changed; command was not admitted",
			));
		}
		base = current["revision"]
			.as_str()
			.and_then(|r| r.parse().ok())
			.ok_or_else(|| Failure::invalid("session returned no workspace revision"))?;
		id = operation()?;
	}
	unreachable!("bounded admission attempts return")
}
async fn command_once(options: &Options, id: &str, base: u64, name: &str, args: &[String]) -> Result<Value, Failure> {
	let envelope = json!({"verb":"command", "id":id, "base":base, "name":name, "args":args});
	let completed = async {
		let deadline = tokio::time::Instant::now() + Duration::from_secs(25);
		loop {
			let mut response = match request(&options.state, envelope.clone()).await {
				Ok(response) => response,
				Err(failure)
					if matches!(
						failure.class.as_str(),
						"rate-limited" | "admission-busy" | "request-too-large"
					) =>
				{
					return Err(retire_refusal(options, id, failure).await);
				}
				Err(failure) => return Err(failure),
			};
			response["base"] = json!(base);
			match response["status"].as_str() {
				Some("conflict") => {
					request(&options.state, json!({"verb":"release-command","id":id})).await?;
					return Ok(response);
				}
				Some("committed") => {
					let result = request(
						&options.state,
						json!({"verb":"command-result","id":id,"base":base,"name":name,"args":args}),
					)
					.await?;
					response["result"] = result["result"].clone();
					response["adopted"] = result["adopted"].clone();
					// Durable result custody belongs to Loam; this retires only
					// the socket adapter's completed admission observation.
					request(&options.state, json!({"verb":"release-command","id":id})).await?;
					return Ok(response);
				}
				Some("pending") if tokio::time::Instant::now() < deadline => {
					tokio::time::sleep(Duration::from_millis(100)).await;
				}
				Some("unsent") => {
					// Observe the original outcome without dispatching it again.
					let result = request(
						&options.state,
						json!({"verb":"command-result","id":id,"base":base,"name":name,"args":args}),
					)
					.await;
					let failure = result
						.err()
						.unwrap_or_else(|| Failure::new("refused", "after-state-change", "command was not sent"));
					// A lost result read still needs its exact observation. A
					// confirmed refusal can retire it without hiding the reason.
					return Err(retire_refusal(options, id, failure).await);
				}
				_ => {
					return Err(Failure::uncertain(format!(
						"command outcome requires recovery: {}",
						response["status"]
					)));
				}
			}
		}
	};
	completed.await.map_err(|mut error: Failure| {
		error.message = if error.class == "uncertain" {
			format!(
				"operation {id}, base {base}: {}; retain both for exact replay",
				error.message
			)
		} else {
			format!("operation {id}, base {base}: {}", error.message)
		};
		error
	})
}

/// Known absence retires only the socket observation. A missed answer keeps
/// that observation. Failed retirement preserves both refusal and cleanup.
async fn retire_refusal(options: &Options, id: &str, failure: Failure) -> Failure {
	if failure.class == "uncertain" {
		return failure;
	}
	match request(&options.state, json!({"verb":"release-command","id":id})).await {
		Ok(_) => failure,
		Err(cleanup) => Failure::new(
			"cleanup",
			"after-state-change",
			format!("{failure}; local observation release failed: {cleanup}; retain the original request for cleanup"),
		),
	}
}

#[cfg(test)]
mod tests;
