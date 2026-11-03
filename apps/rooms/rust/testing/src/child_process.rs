//! A child process that a test owns and the guard reaps. `/bin/kill` delivers
//! the signals a test sends, so the test exercises the executable's own signal
//! handling rather than a library's. Dropping the guard kills and waits for the
//! child, so a failed assertion never leaves an executable running.

use std::{
	process::{Child, Command, ExitStatus},
	time::{Duration, Instant},
};

/// How long [`Process::wait`] waits unless [`Process::within`] says otherwise.
const DEFAULT_DEADLINE: Duration = Duration::from_secs(5);

/// A spawned executable, named for the messages of the test that spawned it.
pub struct Process {
	/// The child, for the pipes and process id a test reads.
	pub child: Child,
	name: &'static str,
	deadline: Duration,
}

impl Process {
	/// Guard `child`. `name` says which executable it is in a failure message,
	/// such as "archive" in "archive process did not finish".
	pub fn new(child: Child, name: &'static str) -> Self {
		Self {
			child,
			name,
			deadline: DEFAULT_DEADLINE,
		}
	}

	/// Wait up to `deadline` for the child to finish instead of the default.
	#[must_use]
	pub fn within(mut self, deadline: Duration) -> Self {
		self.deadline = deadline;
		self
	}

	/// Wait for the child to finish, and fail the test when it outlasts the
	/// deadline. A child that already finished returns its status again.
	pub fn wait(&mut self) -> ExitStatus {
		let deadline = Instant::now() + self.deadline;
		loop {
			match self.child.try_wait() {
				Ok(Some(status)) => return status,
				Ok(None) => {}
				Err(error) => panic!("{} process status: {error}", self.name),
			}
			assert!(Instant::now() < deadline, "{} process did not finish", self.name);
			std::thread::sleep(Duration::from_millis(5));
		}
	}

	/// Send `signal`, such as `-TERM`, and wait for the child to finish. Every
	/// signal but `-KILL` must end the child cleanly; `-KILL` must not.
	pub fn signal(&mut self, signal: &str) {
		let delivered = Command::new("/bin/kill")
			.args([signal, &self.child.id().to_string()])
			.status();
		match delivered {
			Ok(status) => assert!(
				status.success(),
				"{} process: kill {signal} failed: {status}",
				self.name
			),
			Err(error) => panic!("{} process: run /bin/kill {signal}: {error}", self.name),
		}
		let status = self.wait();
		assert_eq!(
			status.success(),
			signal != "-KILL",
			"{} process: unexpected exit status {status} after {signal}",
			self.name
		);
	}
}

impl Drop for Process {
	fn drop(&mut self) {
		// best-effort: the child may have finished already, and a drop has no
		// caller to report to; an unreaped child is what this guard prevents.
		let _ = self.child.kill();
		let _ = self.child.wait();
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn sleeper() -> Child {
		Command::new("sleep").arg("60").spawn().unwrap()
	}

	fn running(id: u32) -> bool {
		Command::new("/bin/kill")
			.args(["-0", &id.to_string()])
			.status()
			.unwrap()
			.success()
	}

	#[test]
	fn dropping_the_guard_kills_and_reaps_the_child() {
		let process = Process::new(sleeper(), "sleeper");
		let id = process.child.id();
		assert!(running(id));
		drop(process);
		assert!(!running(id));
	}

	#[test]
	fn a_kill_signal_is_the_one_signal_that_ends_the_child_uncleanly() {
		let mut process = Process::new(sleeper(), "sleeper");
		process.signal("-KILL");
		assert!(!process.wait().success());
	}

	#[test]
	#[should_panic(expected = "sleeper process did not finish")]
	fn a_child_that_outlasts_the_deadline_fails_the_test() {
		Process::new(sleeper(), "sleeper")
			.within(Duration::from_millis(50))
			.wait();
	}

	#[test]
	#[should_panic(expected = "unexpected exit status")]
	fn a_clean_signal_that_kills_the_child_fails_the_test() {
		// `sleep` has no handler, so it dies of the signal instead of exiting 0.
		Process::new(sleeper(), "sleeper").signal("-TERM");
	}
}
