//! The request the Zig front hands `rooms-bot`, in the shape `rooms-session`
//! receives: `rooms-bot control <json>` with a verb, the bot directory, the named
//! flags, and positional arguments. Zig owns argv syntax and help.
use super::error::Error;
use serde::Deserialize;
use std::{collections::BTreeMap, path::PathBuf};

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
		// A verb a harness runs takes its bot from the turn, and every other
		// verb names its bot directory.
		let turn_verb = super::act::Verb::named(&request.verb).is_some();
		match (request.state.as_os_str().is_empty(), turn_verb) {
			(true, false) => return Err(Error::Usage("--dir is required".into())),
			(false, true) => {
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
			let name = format!("GLOWCAP_ROOMS_BOT_{}", flag.replace('-', "_").to_uppercase());
			if let Some(value) = lookup(&name).filter(|value| !value.is_empty()) {
				filled.named.insert((*flag).to_owned(), vec![value]);
				filled.environment.push((*flag).to_owned());
			}
		}
		filled
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

#[cfg(test)]
mod tests {
	use super::*;

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
