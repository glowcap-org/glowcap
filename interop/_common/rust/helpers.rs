//! Shared helpers for Rust interop example scripts.
#![allow(dead_code)]

use std::time::Duration;

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, ChildStdout};

pub type Fail = Box<dyn std::error::Error>;
pub const INTEROP_TIMEOUT: Duration = Duration::from_secs(90);

pub fn ignore_port_args() -> Result<(), Fail> {
	for arg in std::env::args().skip(1) {
		if !arg.starts_with("--port=") {
			return Err(format!("unknown argument '{arg}'").into());
		}
	}
	Ok(())
}

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

pub async fn read_swiss(child: &mut Child) -> Result<String, Fail> {
	let stdout = child.stdout.take().ok_or("no child stdout")?;
	let mut lines = BufReader::new(stdout).lines();
	let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
	loop {
		match tokio::time::timeout_at(deadline, lines.next_line()).await?? {
			Some(line) => {
				if let Some(swiss) = extract_swiss(&line) {
					return Ok(swiss);
				}
			}
			None => return Err("never saw the readiness line".into()),
		}
	}
}

pub fn extract_swiss(line: &str) -> Option<String> {
	extract_readiness_field(line, "swiss")
}

pub fn extract_sturdyref_path(line: &str) -> Option<String> {
	extract_readiness_field(line, "sturdyref-path")
}

fn extract_readiness_field(line: &str, field: &str) -> Option<String> {
	let needle = format!("\"{field}\":\"");
	let start = line.find(&needle)? + needle.len();
	let rest = &line[start..];
	let end = rest.find('"')?;
	Some(rest[..end].to_string())
}

pub async fn read_sturdyref_path(child: &mut Child) -> Result<String, Fail> {
	let stdout = child.stdout.take().ok_or("no child stdout")?;
	let mut lines = BufReader::new(stdout).lines();
	let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
	loop {
		match tokio::time::timeout_at(deadline, lines.next_line()).await?? {
			Some(line) => {
				if let Some(path) = extract_sturdyref_path(&line) {
					return Ok(path);
				}
			}
			None => return Err("never saw the sturdyref path readiness field".into()),
		}
	}
}

/// Read an exporter's NDJSON readiness lines until the greeter's appears, or
/// time out. Keeps the reader (rather than the whole `Child`) so a caller that
/// must keep draining the exporter's stdout afterward, to avoid deadlocking it
/// on a full OS pipe, can hand the same reader to a background drain task.
pub async fn await_greeter_ready(reader: &mut BufReader<ChildStdout>) -> Result<(), Fail> {
	let mut line = String::new();
	let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
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
