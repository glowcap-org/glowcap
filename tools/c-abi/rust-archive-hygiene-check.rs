#[path = "../../bindings/rust/archive_hygiene.rs"]
mod archive_hygiene;

use std::process::Command;

fn violation(path: &str) -> Option<String> {
	let output = Command::new("tar")
		.args(["--numeric-owner", "-tvzf", path])
		.env("LC_ALL", "C")
		// Cleared for the same reason build.rs clears it: a harness that
		// stands for a port must run the tar that port runs, not a tar the
		// ambient environment has added flags to.
		.env_remove("TAR_OPTIONS")
		.output()
		.expect("run tar");
	assert!(output.status.success(), "tar list failed");
	archive_hygiene::listing_violation(&String::from_utf8_lossy(&output.stdout), "lib")
}

// Usage: CHECK CLEAN TRAVERSAL HAVE_TRAVERSAL UNSAFE...
fn main() {
	let args: Vec<String> = std::env::args().collect();
	assert!(args.len() >= 5, "usage: clean traversal have_traversal unsafe...");
	assert!(violation(&args[1]).is_none(), "clean archive refused");
	if args[3] == "1" {
		assert!(
			violation(&args[2]).is_some(),
			"unsafe archive accepted: {}",
			args[2]
		);
	}
	for path in &args[4..] {
		assert!(
			violation(path).is_some(),
			"unsafe archive accepted: {}",
			path
		);
	}
}
