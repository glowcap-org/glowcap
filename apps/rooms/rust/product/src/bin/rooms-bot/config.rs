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
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::{Path, PathBuf};

const FILE: &str = "config.json";
/// The `serve` flag that drops the stored instructions file.
pub const NO_INSTRUCTIONS: &str = "no-instructions";
pub const DEFAULT_DEADLINE_SECS: u64 = 600;
const MAX_DEADLINE_SECS: u64 = 24 * 60 * 60;
/// Messages in one conversation the bot answers in an hour, unless set.
pub const DEFAULT_CONVERSATION_LIMIT: u32 = 60;
/// The most messages an hour `--conversation-limit` can allow in one conversation.
const MAX_LIMIT: u32 = 100_000;
/// The most bytes the operator's instructions file may hold.
pub const MAX_INSTRUCTIONS_BYTES: usize = 16_384;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Config {
	pub harness: String,
	pub model: Option<String>,
	pub permission: Permission,
	pub deadline_secs: u64,
	/// The absolute path of the `glowcap` executable the harness is told to use.
	pub glowcap: PathBuf,
	pub conversation_limit: u32,
	/// The absolute path of a file whose text each turn adds to the agent's
	/// instructions.
	pub instructions: Option<PathBuf>,
}

/// A stored document: the settings, and every field beside them, which this
/// bot does not read. Serde's own refusal names only the first such field.
#[derive(Deserialize)]
struct Stored {
	#[serde(flatten)]
	config: Config,
	#[serde(flatten)]
	unread: std::collections::BTreeMap<String, Value>,
}

/// The flags `serve` reads that belong to the configuration.
pub const FLAGS: [&str; 7] = [
	"harness",
	"model",
	"permission",
	"deadline",
	"glowcap",
	"conversation-limit",
	"instructions",
];

/// Every setting `serve` reads as a flag or as a variable: [`FLAGS`] and the
/// session link.
pub fn variable_flags() -> Vec<&'static str> {
	FLAGS.iter().copied().chain([super::link::FLAG]).collect()
}

/// The operator's instructions at `path`, bounded by [`MAX_INSTRUCTIONS_BYTES`].
pub fn instructions(path: &Path) -> Result<String, Error> {
	let unreadable = |reason: String| Error::Config(format!("the instructions file {} {reason}", path.display()));
	let bytes = rooms_platform::storage::read(path, MAX_INSTRUCTIONS_BYTES)
		.map_err(|error| unreadable(format!("cannot be read: {error}")))?
		.ok_or_else(|| unreadable("does not exist".into()))?;
	String::from_utf8(bytes).map_err(|_| unreadable("is not UTF-8 text".into()))
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

/// A whole number from 1 to `max`, or none.
fn ranged<N>(text: &str, max: N) -> Option<N>
where
	N: std::str::FromStr + PartialOrd + From<u8>,
{
	text.parse::<N>().ok().filter(|n| *n >= N::from(1) && *n <= max)
}

impl Config {
	pub fn load(store: &Store) -> Result<Option<Self>, Error> {
		store.read::<Value>(FILE)?.map(Self::decode).transpose()
	}

	/// The settings a stored document holds. A field this bot does not read
	/// is refused with every such field named, so one edit settles it.
	fn decode(document: Value) -> Result<Self, Error> {
		let Stored { config, unread } =
			serde_json::from_value(document).map_err(|error| Error::unreadable(FILE, error))?;
		if unread.is_empty() {
			return Ok(config);
		}
		let names: Vec<&str> = unread.keys().map(String::as_str).collect();
		Err(Error::Config(format!(
			"{FILE} in the bot directory holds {}, which this bot does not read. Delete {} from {FILE} and run serve again",
			names.join(", "),
			if names.len() == 1 { "that field" } else { "those fields" },
		)))
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
		super::store::read_unleased::<Value>(&dir, FILE)?
			.map(Self::decode)
			.transpose()
	}

	/// Lay the request's flags over the stored configuration.
	pub fn resolve(stored: Option<Self>, request: &Request) -> Result<Self, Error> {
		let harness = match (request.single("harness")?, &stored) {
			(Some(name), _) => name.to_owned(),
			(None, Some(stored)) => stored.harness.clone(),
			(None, None) => return Err(Error::Config("--harness is required the first time".into())),
		};
		let permission = Self::permission(stored.as_ref(), request)?;
		let deadline_secs = match request.single("deadline")? {
			Some(text) => ranged(text, MAX_DEADLINE_SECS)
				.ok_or_else(|| Error::Config(format!("--deadline must be 1 to {MAX_DEADLINE_SECS} seconds")))?,
			None => stored
				.as_ref()
				.map_or(DEFAULT_DEADLINE_SECS, |stored| stored.deadline_secs),
		};
		let glowcap = Self::glowcap(stored.as_ref(), request)?;
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
		let instructions_path = Self::instructions_path(stored.as_ref(), request)?;
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
			conversation_limit: match request.single("conversation-limit")? {
				Some(text) => ranged(text, MAX_LIMIT)
					.ok_or_else(|| Error::Config(format!("--conversation-limit must be 1 to {MAX_LIMIT}")))?,
				None => stored
					.as_ref()
					.map_or(DEFAULT_CONVERSATION_LIMIT, |stored| stored.conversation_limit),
			},
			instructions: instructions_path,
		})
	}

	/// The permission the request names, else the stored one. Only the flag
	/// raises a stored `safe` to `full`, never the environment.
	fn permission(stored: Option<&Self>, request: &Request) -> Result<Permission, Error> {
		let permission = match request.single("permission")? {
			Some(name) => {
				Permission::parse(name).ok_or_else(|| Error::Config("--permission must be safe or full".into()))?
			}
			None => stored.map_or_else(Permission::default, |stored| stored.permission),
		};
		let raised =
			stored.is_some_and(|stored| stored.permission == Permission::Safe && permission == Permission::Full);
		if raised && request.came_from_environment("permission") {
			return Err(Error::Config(
				"GLOWCAP_ROOMS_BOT_PERMISSION=full does not raise a bot stored as safe. To let this bot do anything you can, run serve once with --permission full"
					.into(),
			));
		}
		Ok(permission)
	}

	/// The glowcap executable the request names, else the stored one, else the
	/// installed one.
	fn glowcap(stored: Option<&Self>, request: &Request) -> Result<PathBuf, Error> {
		match request.single("glowcap")? {
			Some(path) => absolute(Path::new(path)),
			None => stored
				.map(|stored| stored.glowcap.clone())
				.or_else(installed_glowcap)
				.ok_or_else(|| Error::Config("pass --glowcap with the path of the glowcap executable".into())),
		}
	}

	/// The instructions file the request names, else the stored one, unless the
	/// request drops it.
	fn instructions_path(stored: Option<&Self>, request: &Request) -> Result<Option<PathBuf>, Error> {
		match (
			request.single("instructions")?,
			request.named.contains_key(NO_INSTRUCTIONS),
		) {
			(Some(_), true) if !request.came_from_environment("instructions") => Err(Error::Usage(format!(
				"--instructions and --{NO_INSTRUCTIONS} cannot be given together"
			))),
			(_, true) => Ok(None),
			(Some(path), false) => absolute(Path::new(path)).map(Some),
			(None, false) => Ok(stored.and_then(|stored| stored.instructions.clone())),
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_testing::scratch::Scratch;
	use std::os::unix::fs::PermissionsExt;

	#[test]
	fn a_bounded_number_is_whole_and_in_range() {
		assert_eq!(ranged("1", MAX_LIMIT), Some(1));
		assert_eq!(ranged("0", MAX_LIMIT), None);
		assert_eq!(ranged("100001", MAX_LIMIT), None);
		assert_eq!(ranged("-1", MAX_DEADLINE_SECS), None);
		assert_eq!(ranged("1.5", MAX_DEADLINE_SECS), None);
		assert_eq!(ranged("86400", MAX_DEADLINE_SECS), Some(86_400));
		assert_eq!(ranged("86401", MAX_DEADLINE_SECS), None);
	}

	#[test]
	fn the_help_states_the_defaults_and_bounds() {
		let help = include_str!("../../../../../../../cli/app/rooms/bot_commands.zig");
		for said in [
			format!("({DEFAULT_DEADLINE_SECS} unless set)"),
			format!("({DEFAULT_CONVERSATION_LIMIT} unless set)"),
			format!(
				"up to {},{:03} bytes",
				MAX_INSTRUCTIONS_BYTES / 1000,
				MAX_INSTRUCTIONS_BYTES % 1000
			),
		] {
			assert!(help.contains(&said), "the CLI help does not say `{said}`");
		}
		assert!(
			help.contains("from 1 up to a day"),
			"the CLI help does not say the deadline's bound"
		);
	}

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
			conversation_limit: DEFAULT_CONVERSATION_LIMIT,
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

	/// The deployment example is the one other place that names the settings'
	/// variables, and the installed tree its check (`bot_example.py`) reads
	/// holds no Rust source, so the example is held to `FLAGS` here, and a
	/// default it quotes is held to the constant.
	#[test]
	fn the_deployment_example_names_only_variables_serve_reads() {
		let example = include_str!("../../../../../web/deploy/docker-compose.override.yml.example");
		let read: Vec<String> = variable_flags()
			.iter()
			.map(|flag| format!("GLOWCAP_ROOMS_BOT_{}", flag.to_uppercase().replace('-', "_")))
			.collect();
		let mut named = 0;
		for word in example.split(|c: char| !(c.is_ascii_alphanumeric() || c == '_')) {
			if word.starts_with("GLOWCAP_ROOMS_BOT_") {
				named += 1;
				assert!(
					read.iter().any(|name| name == word),
					"{word} is not a setting serve reads"
				);
			}
		}
		assert!(named > 0, "the example names no setting");
		let quoted = example
			.lines()
			.find_map(|line| line.split_once("GLOWCAP_ROOMS_BOT_CONVERSATION_LIMIT: "))
			.map(|(_, value)| value.trim_matches('"'));
		assert_eq!(
			quoted,
			Some(DEFAULT_CONVERSATION_LIMIT.to_string().as_str()),
			"the example quotes a conversation limit other than the default"
		);
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
	fn the_flag_that_drops_instructions_wins_over_the_variable_that_names_them() {
		let (_dir, path) = glowcap();
		let env = |name: &str| (name == "GLOWCAP_ROOMS_BOT_INSTRUCTIONS").then(|| "/not/read".to_owned());
		let dropped = request(r#"{"no-instructions":["true"]}"#).with_environment(&FLAGS, env);
		assert_eq!(
			Config::resolve(Some(stored(&path)), &dropped).unwrap().instructions,
			None
		);
		let named = request(r#"{"no-instructions":["true"],"instructions":["/not/read"]}"#);
		assert!(matches!(
			Config::resolve(Some(stored(&path)), &named),
			Err(Error::Usage(_))
		));
	}

	#[test]
	fn a_stored_document_with_fields_this_bot_does_not_read_names_every_one() {
		let (_dir, path) = glowcap();
		let document = serde_json::to_value(stored(&path)).unwrap();
		assert_eq!(Config::decode(document.clone()).unwrap(), stored(&path));
		let mut extra = document;
		extra["unread_b"] = serde_json::json!(["a"]);
		extra["unread_a"] = serde_json::json!(3);
		let Err(Error::Config(reason)) = Config::decode(extra) else {
			panic!("fields this bot does not read were accepted");
		};
		assert_eq!(
			reason,
			"config.json in the bot directory holds unread_a, unread_b, which this bot does not read. Delete those \
			 fields from config.json and run serve again"
		);
	}

	#[test]
	fn the_conversation_limit_is_stored_and_a_value_out_of_range_is_refused() {
		let (_dir, path) = glowcap();
		let set = Config::resolve(Some(stored(&path)), &request(r#"{"conversation-limit":["5"]}"#)).unwrap();
		assert_eq!(set.conversation_limit, 5);
		assert_eq!(Config::resolve(Some(set.clone()), &request("{}")).unwrap(), set);
		for flags in [r#"{"conversation-limit":["0"]}"#, r#"{"conversation-limit":["many"]}"#] {
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
		let kept = Config::resolve(Some(set.clone()), &request("{}")).unwrap();
		assert_eq!(kept.instructions.as_deref(), Some(file.as_path()));
		let cleared = Config::resolve(Some(set.clone()), &request(r#"{"no-instructions":["true"]}"#)).unwrap();
		assert_eq!(cleared.instructions, None);
		let both = format!(
			r#"{{"no-instructions":["true"],"instructions":["{}"]}}"#,
			file.display()
		);
		assert!(Config::resolve(Some(set), &request(&both)).is_err());
	}
}
