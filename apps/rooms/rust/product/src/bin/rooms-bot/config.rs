//! The bot's settings. `serve` writes what its flags name over what the
//! bot directory stored, so a later `serve` with no flags reuses them.
use super::{
	error::Error,
	harness::{self, Permission},
	home,
	link::Link,
	request::Request,
	store::{self, Store},
};
use rooms_application::room::inbox::{nick_refusal, same_nick};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

const FILE: &str = "config.json";
pub const DEFAULT_DEADLINE_SECS: u64 = 600;
const MAX_DEADLINE_SECS: u64 = 24 * 60 * 60;
/// Messages one sender may have answered in an hour, unless set.
pub const DEFAULT_SENDER_LIMIT: u32 = 30;
/// Messages one conversation may have answered in an hour, unless set.
pub const DEFAULT_CONVERSATION_LIMIT: u32 = 60;
/// Replies in a row to one sender in a conversation nobody else speaks in,
/// unless set.
pub const DEFAULT_STREAK_LIMIT: u32 = 10;
const MAX_LIMIT: u32 = 100_000;
/// The most bytes the operator's instructions file may hold.
pub const MAX_INSTRUCTIONS_BYTES: usize = 16_384;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
	pub harness: String,
	pub model: Option<String>,
	pub permission: Permission,
	pub deadline_secs: u64,
	/// The absolute path of the `glowcap` executable the harness is told to use.
	pub glowcap: PathBuf,
	/// The nicknames whose messages start work. Empty means everyone.
	#[serde(default)]
	pub allow: Vec<String>,
	#[serde(default = "sender_limit")]
	pub sender_limit: u32,
	#[serde(default = "conversation_limit")]
	pub conversation_limit: u32,
	#[serde(default = "streak_limit")]
	pub streak_limit: u32,
	/// The absolute path of a file whose text each turn adds to the agent's
	/// instructions.
	#[serde(default)]
	pub instructions: Option<PathBuf>,
}

fn sender_limit() -> u32 {
	DEFAULT_SENDER_LIMIT
}
fn conversation_limit() -> u32 {
	DEFAULT_CONVERSATION_LIMIT
}
fn streak_limit() -> u32 {
	DEFAULT_STREAK_LIMIT
}

/// The flags `serve` reads that belong to the configuration.
pub const FLAGS: [&str; 10] = [
	"harness",
	"model",
	"permission",
	"deadline",
	"glowcap",
	"allow",
	"sender-limit",
	"conversation-limit",
	"streak-limit",
	"instructions",
];

/// The operator's instructions at `path`, bounded by [`MAX_INSTRUCTIONS_BYTES`].
pub fn instructions(path: &Path) -> Result<String, Error> {
	let unreadable = |reason: String| Error::Config(format!("the instructions file {} {reason}", path.display()));
	let bytes = rooms_platform::storage::read(path, MAX_INSTRUCTIONS_BYTES)
		.map_err(|error| unreadable(format!("cannot be read: {error}")))?
		.ok_or_else(|| unreadable("does not exist".into()))?;
	String::from_utf8(bytes).map_err(|_| unreadable("is not UTF-8 text".into()))
}

/// A turn limit flag, from 1 to [`MAX_LIMIT`].
fn limit(request: &Request, flag: &str, stored: Option<u32>, default: u32) -> Result<u32, Error> {
	match request.single(flag)? {
		Some(text) => text
			.parse::<u32>()
			.ok()
			.filter(|count| (1..=MAX_LIMIT).contains(count))
			.ok_or_else(|| Error::Config(format!("--{flag} must be 1 to {MAX_LIMIT}"))),
		None => Ok(stored.unwrap_or(default)),
	}
}

/// The nicknames `--allow` names. Each value may hold several, separated by
/// commas, as `GLOWCAP_ROOMS_BOT_ALLOW` does. A flag given with no name clears
/// the list.
fn allow_list(request: &Request, stored: Option<&Config>) -> Result<Vec<String>, Error> {
	let Some(values) = request.named.get("allow") else {
		return Ok(stored.map(|stored| stored.allow.clone()).unwrap_or_default());
	};
	let mut names: Vec<String> = Vec::new();
	for name in values.iter().flat_map(|value| value.split(',')) {
		let name = name.trim().trim_start_matches('@');
		if name.is_empty() {
			continue;
		}
		if let Some(why) = nick_refusal(name) {
			return Err(Error::Config(format!("--allow {name:?} is not a nickname: {why}")));
		}
		if !names.iter().any(|kept| same_nick(kept, name)) {
			names.push(name.to_owned());
		}
	}
	Ok(names)
}

/// `<prefix>/bin/glowcap`, found from this executable in `<prefix>/libexec`.
fn installed_glowcap() -> Option<PathBuf> {
	let exe = std::env::current_exe().ok()?;
	let candidate = exe.parent()?.parent()?.join("bin").join("glowcap");
	candidate.is_file().then_some(candidate)
}

fn absolute(path: &Path) -> Result<PathBuf, Error> {
	std::path::absolute(path).map_err(Error::io("resolving the glowcap path"))
}

/// Refuse a path that is not an existing executable regular file, since the
/// harness is told to run it and a turn would only find out later.
fn executable(path: &Path) -> Result<(), Error> {
	if super::harness::runnable(path) {
		return Ok(());
	}
	Err(Error::Config(format!(
		"the glowcap path {} is not an existing executable file, so pass --glowcap with the path of the glowcap executable",
		path.display()
	)))
}

impl Config {
	/// What the gate applies.
	pub fn policy(&self) -> super::gate::Policy<'_> {
		super::gate::Policy {
			allow: &self.allow,
			sender_limit: self.sender_limit,
			conversation_limit: self.conversation_limit,
			streak_limit: self.streak_limit,
		}
	}

	pub fn load(store: &Store) -> Result<Option<Self>, Error> {
		store.read(FILE)
	}

	pub fn save(&self, store: &Store) -> Result<(), Error> {
		store.write(FILE, self)
	}

	/// The settings of a bot directory that is configured, read without the
	/// lease so a command can run beside a `serve` that holds it. A directory
	/// is configured once `serve` has stored both its settings and its session
	/// link. One without the other is not, because a service started from it
	/// could not reach a session.
	pub fn configured(dir: &Path) -> Result<Option<Self>, Error> {
		let dir = super::store::directory(dir)?;
		if Link::load(&dir)?.is_none() {
			return Ok(None);
		}
		super::store::read_unleased(&dir, FILE)
	}

	/// Lay the request's flags over the stored configuration.
	pub fn resolve(stored: Option<Self>, request: &Request) -> Result<Self, Error> {
		let harness = match (request.single("harness")?, &stored) {
			(Some(name), _) => name.to_owned(),
			(None, Some(stored)) => stored.harness.clone(),
			(None, None) => return Err(Error::Config("--harness is required the first time".into())),
		};
		let permission = match request.single("permission")? {
			Some(name) => {
				Permission::parse(name).ok_or_else(|| Error::Config("--permission must be safe or full".into()))?
			}
			None => stored
				.as_ref()
				.map_or_else(Permission::default, |stored| stored.permission),
		};
		let raised = stored
			.as_ref()
			.is_some_and(|stored| stored.permission == Permission::Safe && permission == Permission::Full);
		if raised && request.came_from_environment("permission") {
			return Err(Error::Config(
				"GLOWCAP_ROOMS_BOT_PERMISSION=full does not raise a bot stored as safe. To let this bot do anything you can, run serve once with --permission full"
					.into(),
			));
		}
		let deadline_secs = match request.single("deadline")? {
			Some(text) => text
				.parse::<u64>()
				.ok()
				.filter(|secs| (1..=MAX_DEADLINE_SECS).contains(secs))
				.ok_or_else(|| Error::Config(format!("--deadline must be 1 to {MAX_DEADLINE_SECS} seconds")))?,
			None => stored
				.as_ref()
				.map_or(DEFAULT_DEADLINE_SECS, |stored| stored.deadline_secs),
		};
		let glowcap = match request.single("glowcap")? {
			Some(path) => absolute(Path::new(path))?,
			None => match stored
				.as_ref()
				.map(|stored| stored.glowcap.clone())
				.or_else(installed_glowcap)
			{
				Some(path) => path,
				None => {
					return Err(Error::Config(
						"pass --glowcap with the path of the glowcap executable".into(),
					));
				}
			},
		};
		executable(&glowcap)?;
		harness::lookup(&harness, &glowcap)
			.map_err(|error| Error::Config(error.to_string()))?
			.supports(permission, &home::path(&store::directory(&request.state)?))
			.map_err(|reason| {
				Error::Config(format!(
					"--harness {harness} cannot run with --permission {}: {reason}",
					permission.as_str()
				))
			})?;
		let instructions_path = match request.single("instructions")? {
			Some("") => None,
			Some(path) => Some(absolute(Path::new(path))?),
			None => stored.as_ref().and_then(|stored| stored.instructions.clone()),
		};
		if let Some(path) = &instructions_path {
			instructions(path)?;
		}
		Ok(Self {
			harness,
			model: request
				.single("model")?
				.map(str::to_owned)
				.or_else(|| stored.as_ref().and_then(|stored| stored.model.clone())),
			permission,
			deadline_secs,
			glowcap,
			allow: allow_list(request, stored.as_ref())?,
			sender_limit: limit(
				request,
				"sender-limit",
				stored.as_ref().map(|stored| stored.sender_limit),
				DEFAULT_SENDER_LIMIT,
			)?,
			conversation_limit: limit(
				request,
				"conversation-limit",
				stored.as_ref().map(|stored| stored.conversation_limit),
				DEFAULT_CONVERSATION_LIMIT,
			)?,
			streak_limit: limit(
				request,
				"streak-limit",
				stored.as_ref().map(|stored| stored.streak_limit),
				DEFAULT_STREAK_LIMIT,
			)?,
			instructions: instructions_path,
		})
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_testing::scratch::Scratch;
	use std::os::unix::fs::PermissionsExt;

	/// A directory holding an executable `glowcap` stand-in, and its path.
	fn glowcap() -> (Scratch, String) {
		let dir = Scratch::create("bot-config");
		let path = dir.join("glowcap");
		std::fs::write(&path, "#!/bin/sh\n").unwrap();
		std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
		let text = path.to_str().unwrap().to_owned();
		(dir, text)
	}

	fn request(named: &str) -> Request {
		Request::parse(&format!(
			r#"{{"verb":"serve","state":"/w","named":{named},"arguments":[]}}"#
		))
		.unwrap()
	}

	fn stored(glowcap: &str) -> Config {
		Config {
			harness: "fake".into(),
			model: Some("m1".into()),
			permission: Permission::Full,
			deadline_secs: 30,
			glowcap: glowcap.into(),
			allow: Vec::new(),
			sender_limit: DEFAULT_SENDER_LIMIT,
			conversation_limit: DEFAULT_CONVERSATION_LIMIT,
			streak_limit: DEFAULT_STREAK_LIMIT,
			instructions: None,
		}
	}

	#[test]
	fn the_first_serve_names_a_harness_and_the_glowcap_path() {
		let (_dir, path) = glowcap();
		assert!(Config::resolve(None, &request("{}")).is_err());
		assert!(Config::resolve(None, &request(r#"{"harness":["fake"]}"#)).is_ok() == installed_glowcap().is_some());
		let first = Config::resolve(
			None,
			&request(&format!(r#"{{"harness":["fake"],"glowcap":["{path}"]}}"#)),
		)
		.unwrap();
		assert_eq!(first.permission, Permission::Safe);
		assert_eq!(first.deadline_secs, DEFAULT_DEADLINE_SECS);
	}

	#[test]
	fn a_glowcap_path_that_is_not_an_executable_file_is_refused() {
		let (dir, path) = glowcap();
		let plain = dir.join("plain");
		std::fs::write(&plain, "").unwrap();
		std::fs::set_permissions(&plain, std::fs::Permissions::from_mode(0o644)).unwrap();
		let folder = dir.join("folder");
		std::fs::create_dir(&folder).unwrap();
		for refused in [dir.join("missing"), plain, folder, dir.to_path_buf()] {
			let flags = format!(r#"{{"harness":["fake"],"glowcap":["{}"]}}"#, refused.display());
			assert!(
				matches!(Config::resolve(None, &request(&flags)), Err(Error::Config(_))),
				"{}",
				refused.display()
			);
		}
		// A stored path that stopped being one is refused as well.
		std::fs::remove_file(&path).unwrap();
		assert!(matches!(
			Config::resolve(Some(stored(&path)), &request("{}")),
			Err(Error::Config(_))
		));
	}

	#[test]
	fn a_serve_without_flags_reuses_the_stored_settings() {
		let (_dir, path) = glowcap();
		assert_eq!(
			Config::resolve(Some(stored(&path)), &request("{}")).unwrap(),
			stored(&path)
		);
		let changed = Config::resolve(
			Some(stored(&path)),
			&request(r#"{"deadline":["60"],"permission":["safe"]}"#),
		)
		.unwrap();
		assert_eq!((changed.deadline_secs, changed.permission), (60, Permission::Safe));
		assert_eq!(changed.model.as_deref(), Some("m1"));
	}

	#[test]
	fn a_harness_that_cannot_enforce_safe_is_refused_by_name_before_any_turn() {
		let (_dir, path) = glowcap();
		let Err(Error::Config(reason)) = Config::resolve(
			None,
			&request(&format!(
				r#"{{"harness":["pi"],"permission":["safe"],"glowcap":["{path}"]}}"#
			)),
		) else {
			panic!("pi accepted --permission safe");
		};
		assert!(
			reason.contains("--harness pi") && reason.contains("--permission safe"),
			"{reason}"
		);
		let full = request(&format!(
			r#"{{"harness":["pi"],"permission":["full"],"glowcap":["{path}"]}}"#
		));
		assert!(Config::resolve(None, &full).is_ok());
		// A stored safe configuration is refused the same way when the harness changes.
		let stored = Config {
			permission: Permission::Safe,
			..stored(&path)
		};
		assert!(Config::resolve(Some(stored), &request(r#"{"harness":["pi"]}"#)).is_err());
	}

	#[test]
	fn bad_values_are_refused_by_name() {
		let (_dir, path) = glowcap();
		for flags in [
			r#"{"deadline":["0"]}"#,
			r#"{"deadline":["soon"]}"#,
			r#"{"permission":["root"]}"#,
			r#"{"harness":["nope"]}"#,
		] {
			assert!(
				matches!(
					Config::resolve(Some(stored(&path)), &request(flags)),
					Err(Error::Config(_))
				),
				"{flags}"
			);
		}
	}

	/// The deployment check keeps its own list, because the installed tree it
	/// reads holds no Rust source. This holds the two lists together.
	#[test]
	fn the_deployment_check_knows_every_setting_variable() {
		let check = include_str!("../../../../../../../tools/check/deployment/bot_example.py");
		let listed = check
			.split("BOT_VARIABLES = {")
			.nth(1)
			.unwrap()
			.split('}')
			.next()
			.unwrap();
		let mut names: Vec<String> = listed
			.split(',')
			.map(|name| name.trim().trim_matches('"').to_owned())
			.filter(|name| !name.is_empty())
			.collect();
		names.sort();
		let mut flags: Vec<String> = FLAGS
			.iter()
			.chain(&[super::super::link::FLAG])
			.map(|flag| flag.to_uppercase().replace('-', "_"))
			.collect();
		flags.sort();
		assert_eq!(names, flags);
	}

	#[test]
	fn a_variable_never_raises_a_safe_bot_to_full_and_the_flag_does() {
		let (_dir, path) = glowcap();
		let safe = Config {
			permission: Permission::Safe,
			..stored(&path)
		};
		let env = |name: &str| (name == "GLOWCAP_ROOMS_BOT_PERMISSION").then(|| "full".to_owned());
		let by_variable = request("{}").with_environment(&FLAGS, env);
		let Err(Error::Config(reason)) = Config::resolve(Some(safe.clone()), &by_variable) else {
			panic!("a variable raised a safe bot to full");
		};
		assert!(reason.contains("--permission full"), "{reason}");
		let by_flag = request(r#"{"permission":["full"]}"#).with_environment(&FLAGS, env);
		assert_eq!(
			Config::resolve(Some(safe), &by_flag).unwrap().permission,
			Permission::Full
		);
		// A first serve, with nothing stored, takes the variable.
		let first = request(&format!(r#"{{"harness":["fake"],"glowcap":["{path}"]}}"#)).with_environment(&FLAGS, env);
		assert_eq!(Config::resolve(None, &first).unwrap().permission, Permission::Full);
	}

	#[test]
	fn the_allow_list_and_limits_are_stored_and_a_bare_allow_clears_the_list() {
		let (_dir, path) = glowcap();
		let set = Config::resolve(
			Some(stored(&path)),
			&request(r#"{"allow":["ann,@Bob","ann"],"sender-limit":["5"],"streak-limit":["2"]}"#),
		)
		.unwrap();
		assert_eq!(set.allow, ["ann", "Bob"]);
		assert_eq!(
			(set.sender_limit, set.conversation_limit, set.streak_limit),
			(5, DEFAULT_CONVERSATION_LIMIT, 2)
		);
		let kept = Config::resolve(Some(set.clone()), &request("{}")).unwrap();
		assert_eq!(kept, set);
		let cleared = Config::resolve(Some(set), &request(r#"{"allow":[""]}"#)).unwrap();
		assert!(cleared.allow.is_empty());
		for flags in [
			r#"{"sender-limit":["0"]}"#,
			r#"{"conversation-limit":["many"]}"#,
			r#"{"allow":["room"]}"#,
		] {
			assert!(
				matches!(
					Config::resolve(Some(stored(&path)), &request(flags)),
					Err(Error::Config(_))
				),
				"{flags}"
			);
		}
	}

	#[test]
	fn an_instructions_file_must_be_readable_text_within_the_bound() {
		let (dir, path) = glowcap();
		let file = dir.join("instructions.md");
		let with = |file: &Path| request(&format!(r#"{{"instructions":["{}"]}}"#, file.display()));
		assert!(
			Config::resolve(Some(stored(&path)), &with(&file)).is_err(),
			"a missing file"
		);
		std::fs::write(&file, "x".repeat(MAX_INSTRUCTIONS_BYTES + 1)).unwrap();
		assert!(
			Config::resolve(Some(stored(&path)), &with(&file)).is_err(),
			"a file past the bound"
		);
		std::fs::write(&file, "Answer in French.").unwrap();
		let set = Config::resolve(Some(stored(&path)), &with(&file)).unwrap();
		assert_eq!(set.instructions.as_deref(), Some(file.as_path()));
		assert_eq!(instructions(&file).unwrap(), "Answer in French.");
		let cleared = Config::resolve(Some(set), &request(r#"{"instructions":[""]}"#)).unwrap();
		assert_eq!(cleared.instructions, None);
	}
}
