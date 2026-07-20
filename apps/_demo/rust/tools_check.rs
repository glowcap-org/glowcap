//! Shared tools demo check helper.

pub fn check(nick: &str, label: &str, passed: bool) -> bool {
	println!("{nick}: {}, {label}", if passed { "ok" } else { "FAIL" });
	passed
}
