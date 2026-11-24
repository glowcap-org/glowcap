//! The rig's own link checks: each fails on the leak it guards, so a test
//! that passes through them says something. A leak is planted in a command's
//! standard error, a file name, and the bot directory's files, and the check
//! must fail without printing the link.
use super::{
	control::finish,
	rig::{Rig, held_back},
	session_rig::LinkSecret,
};
use std::{
	os::unix::fs::{PermissionsExt, symlink},
	panic::{AssertUnwindSafe, catch_unwind},
	process::Command,
};

const LINK: &str = "ocapn://wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd.onion/s/eQjP4nR28ffX5eoNCK5DWH6DT_d7BIqD3-My459CUbU";
const SWISS: &str = "eQjP4nR28ffX5eoNCK5DWH6DT_d7BIqD3-My459CUbU";

/// Makes a directory listable again when it drops, so the scratch guard can
/// remove it even when the test fails.
struct Reopen(std::path::PathBuf);

impl Drop for Reopen {
	fn drop(&mut self) {
		// best-effort: a directory already gone needs no permission back.
		let _ = std::fs::set_permissions(&self.0, std::fs::Permissions::from_mode(0o700));
	}
}

/// The message a check failed with, which must name the place and never the link.
fn refusal(check: impl FnOnce()) -> String {
	let Err(panic) = catch_unwind(AssertUnwindSafe(check)) else {
		panic!("the check passed on a leak");
	};
	let message = panic
		.downcast_ref::<String>()
		.cloned()
		.or_else(|| panic.downcast_ref::<&str>().map(|text| (*text).to_owned()))
		.unwrap_or_default();
	assert!(!message.contains(SWISS), "the refusal printed the link");
	message
}

#[test]
fn a_command_that_prints_the_link_on_standard_error_fails_the_rig() {
	let mut command = Command::new("sh");
	command.args(["-c", "printf '%s\\n' \"$0\" >&2", &format!("rooms bot: refused {LINK}")]);
	let message = refusal(|| {
		finish(command, None, &[LinkSecret::of(LINK)]);
	});
	assert!(message.contains("a control command's standard error"), "{message}");
}

#[test]
fn a_clean_command_passes_through_the_check() {
	let mut command = Command::new("sh");
	command.args(["-c", "echo '{\"ok\":true}'; echo refused >&2"]);
	let (printed, ok) = finish(command, None, &[LinkSecret::of(LINK)]);
	assert!(ok && printed["ok"] == true, "{printed}");
}

#[test]
fn the_link_scan_fails_on_what_it_cannot_read_and_on_a_name_that_holds_the_link() {
	let rig = Rig::new("bot-leaks");
	std::fs::create_dir_all(&rig.dir).unwrap();
	// A directory it cannot list.
	let hidden = rig.dir.join("hidden");
	std::fs::create_dir(&hidden).unwrap();
	std::fs::set_permissions(&hidden, std::fs::Permissions::from_mode(0o000)).unwrap();
	let opened = Reopen(hidden.clone());
	let message = refusal(|| rig.assert_keeps_no_link([LINK]));
	drop(opened);
	assert!(message.contains("cannot read a directory"), "{message}");
	std::fs::remove_dir(&hidden).unwrap();
	// A link the scan would otherwise skip.
	symlink("/etc/hostname", rig.dir.join("pointer")).unwrap();
	let message = refusal(|| rig.assert_keeps_no_link([LINK]));
	assert!(message.contains("link or special file"), "{message}");
	std::fs::remove_file(rig.dir.join("pointer")).unwrap();
	// A file named for the swissnum.
	std::fs::write(rig.dir.join(SWISS), "").unwrap();
	let message = refusal(|| rig.assert_keeps_no_link([LINK]));
	assert!(message.contains("a file name"), "{message}");
	std::fs::remove_file(rig.dir.join(SWISS)).unwrap();
	rig.assert_keeps_no_link([LINK]);
}

#[test]
fn a_failure_dump_holds_back_a_file_with_the_link() {
	let secrets = [LinkSecret::of(LINK)];
	assert_eq!(held_back(&secrets, Ok(format!("log {LINK}"))), "(holds a session link)");
	assert_eq!(
		held_back(&secrets, Ok("a log with no link".into())),
		"a log with no link"
	);
	assert_eq!(
		held_back(&secrets, Ok(format!("log {SWISS}"))),
		"(holds a session link)"
	);
}
