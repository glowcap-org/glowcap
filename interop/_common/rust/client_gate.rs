//! The gate protocol a Rust Goblins interop client speaks: the port argument,
//! the readiness fields in the partner's stdout, and the deadline the whole
//! exchange runs under. Each client compiles its own copy through `#[path]`
//! and reads the readiness field its proof needs, so the unused rest is
//! expected.
#![allow(dead_code)]

use std::time::Duration;

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, ChildStdout};

pub type Fail = Box<dyn std::error::Error>;
pub const INTEROP_TIMEOUT: Duration = Duration::from_secs(90);
const READINESS_DEADLINE: Duration = Duration::from_secs(30);

pub fn parse_port(default: u16, max_port: u16) -> Result<u16, Fail> {
	let mut port = default;
	for arg in std::env::args().skip(1) {
		match arg.strip_prefix("--port=") {
			Some(text) => port = text.parse()?,
			None => return Err(format!("unknown argument '{arg}'").into()),
		}
	}
	if port == 0 || port > max_port {
		return Err(format!("--port must be in 1..{max_port}").into());
	}
	Ok(port)
}

/// The partner's swiss number, from the readiness line it prints on stdout.
pub async fn read_swiss(child: &mut Child) -> Result<String, Fail> {
	read_readiness_field(child, "swiss", "never saw the readiness line").await
}

/// The path of the sturdyref file the partner wrote, from its readiness line.
pub async fn read_sturdyref_path(child: &mut Child) -> Result<String, Fail> {
	read_readiness_field(child, "sturdyref-path", "never saw the sturdyref path readiness field").await
}

/// Take the child's stdout and read lines until one carries `field`, or the
/// readiness deadline passes. `miss` is the failure when stdout ends first.
async fn read_readiness_field(child: &mut Child, field: &str, miss: &'static str) -> Result<String, Fail> {
	let stdout = child.stdout.take().ok_or("no child stdout")?;
	let mut lines = BufReader::new(stdout).lines();
	let deadline = tokio::time::Instant::now() + READINESS_DEADLINE;
	loop {
		match tokio::time::timeout_at(deadline, lines.next_line()).await?? {
			Some(line) => {
				if let Some(value) = extract_readiness_field(&line, field) {
					return Ok(value);
				}
			}
			None => return Err(miss.into()),
		}
	}
}

fn extract_readiness_field(line: &str, field: &str) -> Option<String> {
	let needle = format!("\"{field}\":\"");
	let start = line.find(&needle)? + needle.len();
	let rest = &line[start..];
	let end = rest.find('"')?;
	Some(rest[..end].to_string())
}

/// Read an exporter's NDJSON readiness lines until the greeter's appears, or
/// time out. Keeps the reader (rather than the whole `Child`) so a caller that
/// must keep draining the exporter's stdout afterward, to avoid deadlocking it
/// on a full OS pipe, can hand the same reader to a background drain task.
pub async fn await_greeter_ready(reader: &mut BufReader<ChildStdout>) -> Result<(), Fail> {
	let mut line = String::new();
	let deadline = tokio::time::Instant::now() + READINESS_DEADLINE;
	loop {
		line.clear();
		let read = tokio::time::timeout_at(deadline, reader.read_line(&mut line)).await??;
		if read == 0 {
			return Err("exporter exited before publishing the greeter".into());
		}
		if line.contains("\"name\":\"greeter\"") {
			return Ok(());
		}
	}
}
