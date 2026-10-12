//! Private command front behind the Zig argv catalog. This composes local
//! requests and session startup. The shared application owns Rooms effects.
mod acquisition;
mod admission;
use admission::command;
mod bootstrap;
mod listen;
mod options;
mod supervise;
mod team;
mod workspace;
use options::Options;
use rooms_services::session::control::Failure;
use serde_json::{Value, json};
use std::{io::Write, path::Path, time::Duration};
use tokio::{
	io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
	net::UnixStream,
};

fn emit(value: &Value) -> Result<(), Failure> {
	let mut output = std::io::stdout().lock();
	serde_json::to_writer(&mut output, value)?;
	writeln!(output)?;
	output.flush()?;
	Ok(())
}
pub(crate) fn operation() -> Result<String, Failure> {
	let mut bytes = [0; 16];
	rooms_platform::entropy::fill(&mut bytes).map_err(|error| Failure::new("entropy", "after-state-change", error))?;
	Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
async fn request(state: &Path, request: Value) -> Result<Value, Failure> {
	request_encoded(
		state,
		request["verb"].as_str().unwrap_or("control request"),
		&serde_json::to_vec(&request)?,
	)
	.await
}
async fn request_encoded(state: &Path, verb: &str, encoded: &[u8]) -> Result<Value, Failure> {
	let result = tokio::time::timeout(Duration::from_secs(40), async {
		let mut stream = UnixStream::connect(state.join("control.sock")).await?;
		let mut bytes = encoded.to_vec();
		bytes.push(b'\n');
		if bytes.len() > 1024 * 1024 {
			return Err(Failure::exhausted("control request exceeds 1 MiB"));
		}
		stream.write_all(&bytes).await?;
		let mut read = BufReader::new(stream);
		let mut bytes = Vec::new();
		loop {
			let available = read.fill_buf().await.map_err(Failure::uncertain)?;
			if available.is_empty() {
				return Err(Failure::uncertain(
					"control response interrupted; inspect status before retrying",
				));
			}
			let end = available.iter().position(|b| *b == b'\n');
			let count = end.map_or(available.len(), |i| i + 1);
			if bytes.len() + count > 20 * 1024 * 1024 {
				return Err(Failure::uncertain(
					"control response exceeds 20 MiB; inspect the session before retrying",
				));
			}
			bytes.extend_from_slice(&available[..count]);
			read.consume(count);
			if end.is_some() {
				break;
			}
		}
		let reply: Value = serde_json::from_slice(&bytes).map_err(Failure::uncertain)?;
		if reply["ok"] != true {
			return Err(serde_json::from_value(reply["error"].clone()).map_err(Failure::uncertain)?);
		}
		Ok(reply)
	})
	.await;
	result
		.map_err(|_| Failure::uncertain("control deadline expired; inspect status before retrying"))?
		.map_err(|mut error: Failure| {
			error.message = format!("{verb}: {}", error.message);
			error
		})
}
async fn execute(options: &Options) -> Result<Value, Failure> {
	match options.verb.as_str() {
		"start" => supervise::start(options).await,
		"join" => workspace::join(options).await,
		"recover" => acquisition::recover(options).await,
		"tick" => {
			request(
				&options.state,
				json!({"verb":"tick", "wait":options.number("wait",30)?, "after_id":options.number("after-id",0)?}),
			)
			.await
		}
		"reply" => {
			let target = workspace::target(options).await?;
			let text = options
				.get("text")
				.ok_or_else(|| Failure::invalid("reply needs --text"))?;
			// Refuse an unreadable event number before the reply is sent.
			let acknowledged = options
				.get("id")
				.map(|id| {
					id.parse::<u64>()
						.map_err(|_| Failure::invalid("--id needs an unsigned integer"))
				})
				.transpose()?;
			let sent = command(options, "say", vec![target, text.into()]).await?;
			if let Some(id) = acknowledged
				&& let Err(error) = request(&options.state, json!({"verb":"ack", "ids":[id]})).await
			{
				return Err(Failure::uncertain(format!(
					"reply completed (operation {}), but acknowledgment failed: {error}; dismiss the event, do not resend",
					sent["operation"]
				)));
			}
			Ok(sent)
		}
		"leave" => command(options, "leaveConversation", vec![workspace::target(options).await?]).await,
		"dismiss" => {
			let ids = options
				.values("id")
				.iter()
				.map(|id| id.parse::<u64>())
				.collect::<Result<Vec<_>, _>>()
				.map_err(|_| Failure::invalid("--id needs an unsigned integer"))?;
			request(&options.state, json!({"verb":"ack", "ids":ids})).await
		}
		"resume" => request(&options.state, json!({"verb":"resume"})).await,
		"command" => command(options, &options.arguments[0], options.arguments[1..].to_vec()).await,
		"stop" => {
			let result = request(&options.state, json!({"verb":"stop"})).await?;
			let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
			while options.state.join("control.sock").exists() {
				if tokio::time::Instant::now() >= deadline {
					return Err(Failure::uncertain("session is still stopping; inspect control.log"));
				}
				tokio::time::sleep(Duration::from_millis(50)).await;
			}
			Ok(result)
		}
		"status" => request(&options.state, json!({"verb":"status"})).await,
		_ => Err(Failure::invalid("unknown Rooms command")),
	}
}
pub async fn run(body: &str) -> Result<(), String> {
	let result = async {
		let options = Options::read(body)?;
		if options.verb.starts_with("team-") {
			return team::run(&options).await;
		}
		if options.verb == "listen" {
			return listen::run(&options.state).await;
		}
		execute(&options).await
	}
	.await;
	match result {
		Ok(value) => {
			emit(&value).map_err(|error| error.to_string())?;
			if value["ok"] == true {
				Ok(())
			} else {
				Err("some team members failed; inspect the member results".into())
			}
		}
		Err(error) => {
			emit(&error.response()).map_err(|e| e.to_string())?;
			Err(error.to_string())
		}
	}
}
