//! The build script's bounded-size release transfer, isolated from user curl
//! configuration. Transport policy is selected by the caller.
use std::io;
use std::path::Path;
use std::process::Command;

pub fn download(
	url: &str,
	destination: &Path,
	user_agent: &str,
	max_bytes: u64,
	transport_args: &[&str],
) -> io::Result<bool> {
	// -q must be the first argument to suppress the default curl config.
	Command::new("curl")
		.args(["-q", "-fsSL"])
		.args(transport_args)
		.arg("--max-filesize")
		.arg(max_bytes.to_string())
		.args(["-A", user_agent, "-o"])
		.arg(destination)
		.arg(url)
		.status()
		.map(|status| status.success())
}
