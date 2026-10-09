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
			let mut response = request(&options.state, envelope.clone()).await?;
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
		error.message = format!(
			"operation {id}, base {base}: {}; retain both for exact replay",
			error.message
		);
		error
	})
}

#[cfg(test)]
mod tests;
