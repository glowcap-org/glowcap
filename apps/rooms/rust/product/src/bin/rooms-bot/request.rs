//! The request the Zig front hands `rooms-bot`, in the shape `rooms-session`
//! receives: `rooms-bot control <json>` with a verb, the bot directory, the named
//! flags, and positional arguments. Zig owns argv syntax and help.
use super::error::Error;
use serde::Deserialize;
use std::{collections::BTreeMap, ffi::OsString, path::PathBuf};

const MAX_BODY_BYTES: usize = 1024 * 1024;

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
	pub verb: String,
	pub state: PathBuf,
	pub named: BTreeMap<String, Vec<String>>,
	pub arguments: Vec<String>,
	/// The flags a variable filled rather than the command line.
	#[serde(skip)]
	environment: Vec<String>,
}

impl Request {
	pub fn parse(body: &str) -> Result<Self, Error> {
		if body.len() > MAX_BODY_BYTES {
			return Err(Error::Usage("the request exceeds 1 MiB".into()));
		}
		let request: Self =
			serde_json::from_str(body).map_err(|error| Error::Usage(format!("unreadable request: {error}")))?;
		// A turn supplies its own bot directory. Schedule controls also run
		// outside a turn, where the operator must name a directory.
		let verb = super::act::Verb::named(&request.verb);
		match (request.state.as_os_str().is_empty(), verb) {
			(true, None) => return Err(Error::Usage("--dir is required".into())),
			(false, Some(verb)) if !verb.operator_schedule_control() => {
				return Err(Error::Usage(format!(
					"{} takes its bot directory from the turn and no --dir",
					request.verb
				)));
			}
			_ => {}
		}
		if request.verb != "command" && !request.arguments.is_empty() {
			return Err(Error::Usage(format!("{} takes no positional arguments", request.verb)));
		}
		Ok(request)
	}

	/// Refuse a flag this verb does not read, instead of ignoring it.
	pub fn only(&self, allowed: &[&str]) -> Result<(), Error> {
		match self.named.keys().find(|key| !allowed.contains(&key.as_str())) {
			Some(key) => Err(Error::Usage(format!("{} does not take --{key}", self.verb))),
			None => Ok(()),
		}
	}

	/// Settings a flag left out takes from `GLOWCAP_ROOMS_BOT_<NAME>`, with
	/// dashes as underscores, as `rooms-session` and `rooms-server` read theirs.
	/// A flag wins over its variable, and an empty variable is no setting.
	pub fn with_environment(&self, flags: &[&str], lookup: impl Fn(&str) -> Option<String>) -> Self {
		let mut filled = self.clone();
		for flag in flags {
			if filled.named.get(*flag).is_some_and(|values| !values.is_empty()) {
				continue;
			}
			let name = variable(flag);
			if let Some(value) = lookup(&name).filter(|value| !value.is_empty()) {
				filled.named.insert((*flag).to_owned(), vec![value]);
				filled.environment.push((*flag).to_owned());
			}
		}
		filled
	}

	/// Refuse a `GLOWCAP_ROOMS_BOT_` variable whose name or value is not
	/// Unicode, because the setting it carries could not be read and would be
	/// ignored. The refusal names the variable and never its value.
	pub fn refuse_unreadable_variables(variables: &[(OsString, OsString)]) -> Result<(), Error> {
		use std::os::unix::ffi::OsStrExt;
		let ours = |name: &OsString| name.as_bytes().starts_with(PREFIX.as_bytes());
		match variables
			.iter()
			.find(|(name, value)| ours(name) && (name.to_str().is_none() || value.to_str().is_none()))
		{
			None => Ok(()),
			Some((name, _)) => Err(Error::Config(format!(
				"{} is set to text that is not Unicode. Unset it, or set it to the setting's value as plain text",
				name.to_string_lossy()
			))),
		}
	}

	/// Refuse a `GLOWCAP_ROOMS_BOT_` variable that names no setting, because a
	/// misspelled one would otherwise be ignored and the bot would run on
	/// defaults. `names` is the environment's variable names and `known` the
	/// flags whose variables are read, plus `extra` full names that are read
	/// elsewhere.
	pub fn refuse_unknown_variables(
		names: impl IntoIterator<Item = String>,
		known: &[&str],
		extra: &[&str],
	) -> Result<(), Error> {
		let read = |name: &str| extra.contains(&name) || known.iter().any(|flag| name == variable(flag));
		let mut unknown: Vec<String> = names
			.into_iter()
			.filter(|name| name.starts_with(PREFIX) && !read(name))
			.collect();
		unknown.sort();
		if unknown.is_empty() {
			return Ok(());
		}
		let (set, are, verb, unset) = match unknown.as_slice() {
			[only] => (only.clone(), "is", "variable", "it"),
			_ => (unknown.join(", "), "are", "variables", "them"),
		};
		Err(Error::Config(format!(
			"{set} {are} set, and serve reads no such {verb}. Unset {unset}"
		)))
	}

	/// Whether `flag`'s value came from its variable.
	pub fn came_from_environment(&self, flag: &str) -> bool {
		self.environment.iter().any(|filled| filled == flag)
	}

	/// The value of a flag that may be given once.
	pub fn single(&self, key: &str) -> Result<Option<&str>, Error> {
		match self.named.get(key).map(Vec::as_slice) {
			None | Some([]) => Ok(None),
			Some([value]) => Ok(Some(value)),
			Some(_) => Err(Error::Usage(format!("--{key} may be given once"))),
		}
	}
}

/// The start of every variable `serve` reads.
const PREFIX: &str = "GLOWCAP_ROOMS_BOT_";

/// The variable that carries `flag`: the one rule `with_environment` fills by
/// and `refuse_unknown_variables` accepts by.
fn variable(flag: &str) -> String {
	format!("{PREFIX}{}", flag.replace('-', "_").to_uppercase())
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_variable_serve_does_not_read_is_refused_by_name() {
		let names = |list: &[&str]| list.iter().map(|name| (*name).to_owned()).collect::<Vec<_>>();
		let known = ["harness", "conversation-limit"];
		let extra = ["GLOWCAP_ROOMS_BOT_FAULT"];
		let ok = names(&[
			"PATH",
			"GLOWCAP_ROOMS_BOT_HARNESS",
			"GLOWCAP_ROOMS_BOT_CONVERSATION_LIMIT",
			"GLOWCAP_ROOMS_BOT_FAULT",
		]);
		assert!(Request::refuse_unknown_variables(ok, &known, &extra).is_ok());
		let refused = |set: &[&str]| match Request::refuse_unknown_variables(names(set), &known, &extra) {
			Err(Error::Config(said)) => said,
			other => panic!("an unknown variable was accepted: {other:?}"),
		};
		assert_eq!(
			refused(&["GLOWCAP_ROOMS_BOT_UNKNOWN"]),
			"GLOWCAP_ROOMS_BOT_UNKNOWN is set, and serve reads no such variable. Unset it"
		);
		assert_eq!(
			refused(&["GLOWCAP_ROOMS_BOT_HARNES", "GLOWCAP_ROOMS_BOT_UNKNOWN"]),
			"GLOWCAP_ROOMS_BOT_HARNES, GLOWCAP_ROOMS_BOT_UNKNOWN are set, and serve reads no such variables. Unset them"
		);
	}

	#[test]
	fn a_variable_that_is_not_unicode_is_refused_by_name_and_never_by_value() {
		use std::os::unix::ffi::OsStringExt;
		let pair = |name: &str, value: Vec<u8>| (OsString::from(name), OsString::from_vec(value));
		let secret = b"abc\xff-secret-value".to_vec();
		let Err(Error::Config(said)) =
			Request::refuse_unreadable_variables(&[pair("GLOWCAP_ROOMS_BOT_HARNESS", secret.clone())])
		else {
			panic!("a non-Unicode value was accepted");
		};
		assert!(
			said.starts_with("GLOWCAP_ROOMS_BOT_HARNESS is set to text that is not Unicode"),
			"{said}"
		);
		assert!(!said.contains("secret-value"), "{said}");
		let mut name = b"GLOWCAP_ROOMS_BOT_".to_vec();
		name.push(0xff);
		let odd_name = (OsString::from_vec(name), OsString::from("x"));
		assert!(Request::refuse_unreadable_variables(&[odd_name]).is_err());
		// A variable that is not ours is none of its business.
		assert!(Request::refuse_unreadable_variables(&[pair("OTHER", secret)]).is_ok());
		assert!(Request::refuse_unreadable_variables(&[pair("GLOWCAP_ROOMS_BOT_HARNESS", b"pi".to_vec())]).is_ok());
	}

	fn request(named: &str) -> Request {
		Request::parse(&format!(
			r#"{{"verb":"serve","state":"/w","named":{named},"arguments":[]}}"#
		))
		.unwrap()
	}

	#[test]
	fn flags_are_single_valued_and_known() {
		let request = request(r#"{"harness":["fake"],"model":["a","b"]}"#);
		assert_eq!(request.single("harness").unwrap(), Some("fake"));
		assert_eq!(request.single("absent").unwrap(), None);
		assert!(request.single("model").is_err());
		assert!(request.only(&["harness"]).is_err());
		assert!(request.only(&["harness", "model"]).is_ok());
	}

	#[test]
	fn a_variable_fills_a_flag_left_out_and_never_overrides_one() {
		let env = |name: &str| match name {
			"GLOWCAP_ROOMS_BOT_HARNESS" => Some("pi".to_owned()),
			"GLOWCAP_ROOMS_BOT_MODEL" => Some("from-env".to_owned()),
			"GLOWCAP_ROOMS_BOT_DEADLINE" => Some(String::new()),
			_ => None,
		};
		let filled =
			request(r#"{"model":["from-flag"]}"#).with_environment(&["harness", "model", "deadline", "link"], env);
		assert_eq!(filled.single("harness").unwrap(), Some("pi"));
		assert!(filled.came_from_environment("harness"));
		assert_eq!(filled.single("model").unwrap(), Some("from-flag"));
		assert!(!filled.came_from_environment("model"));
		assert_eq!(filled.single("deadline").unwrap(), None);
		assert_eq!(filled.single("link").unwrap(), None);
	}

	#[test]
	fn a_malformed_request_is_a_usage_error() {
		assert!(Request::parse("{").is_err());
		assert!(Request::parse(r#"{"verb":"serve","state":"","named":{},"arguments":[]}"#).is_err());
		assert!(Request::parse(r#"{"verb":"serve","state":"/w","named":{},"arguments":["x"]}"#).is_err());
		assert!(Request::parse(r#"{"verb":"command","state":"","named":{},"arguments":["x"]}"#).is_ok());
		assert!(Request::parse(r#"{"verb":"say","state":"/w","named":{},"arguments":[]}"#).is_err());
	}
}
