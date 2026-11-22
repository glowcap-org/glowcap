//! A coding harness as the bot sees it: an argument builder and a line
//! parser. The turn runner owns the process, the deadline, and the kill, so
//! an adapter is testable from recorded output with no process.
mod claude;
mod codex;
#[cfg(any(test, feature = "test-support"))]
mod fake;
mod lines;
mod pi;

use serde::{Deserialize, Serialize};
use std::{
	ffi::OsString,
	fmt,
	path::{Path, PathBuf},
};

/// What a harness may touch. `Safe` lets it read and write inside its working
/// directory and run the bot's own glowcap actions, and an adapter that cannot
/// hold its harness to that refuses it. `Full` is an operator choice.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Permission {
	#[default]
	Safe,
	Full,
}

impl Permission {
	pub fn as_str(self) -> &'static str {
		match self {
			Self::Safe => "safe",
			Self::Full => "full",
		}
	}
	pub fn parse(name: &str) -> Option<Self> {
		match name {
			"safe" => Some(Self::Safe),
			"full" => Some(Self::Full),
			_ => None,
		}
	}
}

/// One turn's inputs.
pub struct Turn<'a> {
	pub prompt: &'a str,
	pub system: &'a str,
	/// The harness session to resume.
	pub session: Option<&'a str>,
	pub workdir: &'a Path,
	/// The bot's home, shared by every conversation, which a safe run may
	/// read and write as well as its working directory.
	pub home: &'a Path,
	/// Where the adapter keeps its own state for this conversation, beside the
	/// working directory and outside what a safe run may read.
	pub state: &'a Path,
	pub model: Option<&'a str>,
	pub permission: Permission,
}

/// Directory work a harness needs before it starts. The runner does it, so an
/// adapter stays free of file system effects.
#[derive(Debug, PartialEq, Eq)]
pub enum Prepare {
	/// Create the directory and its parents.
	Dir(PathBuf),
	/// Make `at` a symbolic link to `target`. The target must exist.
	Link { target: PathBuf, at: PathBuf },
	/// Write `contents` to `at`, replacing what was there.
	File { at: PathBuf, contents: String },
}

pub struct Invocation {
	pub program: OsString,
	pub args: Vec<OsString>,
	pub env: Vec<(OsString, OsString)>,
	pub stdin: Option<String>,
	/// Work to finish before the process starts.
	pub prepare: Vec<Prepare>,
	/// The harness session this run asks to continue. A harness that reports a
	/// different session has lost the conversation, and the runner fails the turn.
	pub resume: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FailureKind {
	Auth,
	RateLimit,
	Refused,
	Crash,
}

impl FailureKind {
	/// Words for the line the bot posts when a turn fails this way.
	pub fn label(self) -> &'static str {
		match self {
			Self::Auth => "the agent refused its sign-in",
			Self::RateLimit => "the agent hit a usage limit",
			Self::Refused => "the agent declined the request",
			Self::Crash => "the agent stopped unexpectedly",
		}
	}
	/// Whether running the same turn again can succeed.
	pub fn retryable(self) -> bool {
		self == Self::Crash
	}
}

/// What one stdout line of the harness means.
#[derive(Debug, PartialEq, Eq)]
pub enum Signal {
	/// The session id to resume next time.
	Session(String),
	/// The agent used a tool, so it is at work on the turn.
	Activity,
	/// Assistant text so far, or a delta when [`Harness::text_is_delta`].
	Text(String),
	/// The turn's final answer.
	Final(String),
	Failure(FailureKind, String),
}

pub trait Harness {
	fn name(&self) -> &'static str;
	/// The program every invocation runs: a bare name found on `PATH`, or a
	/// path.
	fn program(&self) -> OsString;
	/// Refuse a permission this harness cannot enforce, with the reason an
	/// operator needs. `serve` asks before any turn runs, so a harness never
	/// runs with less confinement than was requested. `home` is the bot's
	/// home, which a safe run may write as well as its working directory.
	fn supports(&self, _permission: Permission, _home: &Path) -> Result<(), String> {
		Ok(())
	}
	fn invocation(&self, turn: &Turn<'_>) -> Invocation;
	/// Unknown lines yield nothing.
	fn read(&self, line: &str) -> Vec<Signal>;
	/// Whether [`Signal::Text`] carries a delta to append or the text so far.
	fn text_is_delta(&self) -> bool {
		false
	}
	/// Classify an exit that produced no final answer.
	fn exit(&self, code: Option<i32>, stderr_tail: &str) -> Option<(FailureKind, String)>;
}

/// One registry row. Adding an adapter is one file and one row here. `build`
/// receives the absolute path of the `glowcap` executable a safe harness may run.
struct Adapter {
	name: &'static str,
	build: fn(&Path) -> Box<dyn Harness>,
}

const ADAPTERS: &[Adapter] = &[
	Adapter {
		name: "claude",
		build: |glowcap| Box::new(claude::Claude::new(glowcap)),
	},
	Adapter {
		name: "codex",
		build: |_| Box::new(codex::Codex::from_environment()),
	},
	Adapter {
		name: "pi",
		build: |_| Box::new(pi::Pi),
	},
	#[cfg(any(test, feature = "test-support"))]
	Adapter {
		name: "fake",
		build: |_| Box::new(fake::Fake),
	},
];

/// The name of every harness this build can run.
pub fn names() -> impl Iterator<Item = &'static str> {
	ADAPTERS.iter().map(|adapter| adapter.name)
}

#[derive(Debug)]
pub struct UnknownHarness(String);

impl fmt::Display for UnknownHarness {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		let names: Vec<_> = names().collect();
		write!(f, "unknown harness {:?}. Choose one of: {}", self.0, names.join(", "))
	}
}

/// Whether `at` is an existing regular file someone may execute.
pub fn runnable(at: &Path) -> bool {
	use std::os::unix::fs::PermissionsExt;
	std::fs::metadata(at).is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

/// Where `harness`'s program is, found the way the runner's spawn finds it: a
/// path as itself, and a bare name in each `PATH` directory in turn. The
/// refusal names the program and where it was looked for.
pub fn present(harness: &dyn Harness, path: Option<&std::ffi::OsStr>) -> Result<PathBuf, String> {
	let program = PathBuf::from(harness.program());
	if program.components().count() > 1 {
		return if runnable(&program) {
			Ok(program)
		} else {
			Err(format!(
				"the agent program {} is not an executable file",
				program.display()
			))
		};
	}
	let path = path.unwrap_or_default();
	std::env::split_paths(path)
		.map(|directory| directory.join(&program))
		.find(|candidate| runnable(candidate))
		.ok_or_else(|| {
			format!(
				"--harness {} runs {}, and no executable of that name is on this process's PATH ({}). Install the agent where the bot runs, in the container image for a container, and sign it in",
				harness.name(),
				program.display(),
				path.to_string_lossy()
			)
		})
}

pub fn lookup(name: &str, glowcap: &Path) -> Result<Box<dyn Harness>, UnknownHarness> {
	ADAPTERS
		.iter()
		.find(|adapter| adapter.name == name)
		.map(|adapter| (adapter.build)(glowcap))
		.ok_or_else(|| UnknownHarness(name.into()))
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::os::unix::fs::PermissionsExt;

	#[test]
	fn an_agent_is_found_on_path_or_refused_by_name() {
		let scratch = rooms_testing::scratch::Scratch::create("bot-agent-path");
		let (empty, holder) = (scratch.join("empty"), scratch.join("bin"));
		std::fs::create_dir_all(&empty).unwrap();
		std::fs::create_dir_all(&holder).unwrap();
		let claude = lookup("claude", Path::new("/opt/glowcap")).unwrap();
		let path = std::env::join_paths([&empty, &holder]).unwrap();
		let refused = present(&*claude, Some(&path)).unwrap_err();
		assert!(
			refused.contains("--harness claude runs claude") && refused.contains(&holder.display().to_string()),
			"{refused}"
		);
		std::fs::write(holder.join("claude"), "").unwrap();
		assert!(
			present(&*claude, Some(&path)).is_err(),
			"a file that is not executable is no agent"
		);
		std::fs::set_permissions(holder.join("claude"), std::fs::Permissions::from_mode(0o755)).unwrap();
		assert_eq!(present(&*claude, Some(&path)).unwrap(), holder.join("claude"));
		assert!(present(&*claude, None).is_err());
	}
}
