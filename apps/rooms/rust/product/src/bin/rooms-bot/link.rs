//! The session link the bot attaches with. It is a capability: whoever holds
//! it holds the access it was issued with. So it lives in its own owner-only
//! file in the bot directory, and nothing here prints it. A [`Link`] has no
//! `Display`, its `Debug` hides the text, and a refusal never quotes it. It
//! arrives on standard input or in a file, never as a command-line value,
//! because every process on the machine can read a command line. What it
//! holds may be the bare link or the JSON line `session access issue` prints.
use super::{error::Error, request::Request, store::Store};
use rooms_platform::storage;
use std::{
	fmt,
	io::{BufRead, Read},
	path::Path,
};

pub const FILE: &str = "session.link";
/// The longest link the bot reads. Links are one line.
const MAX_BYTES: usize = 4096;
/// The `serve` flag that names where the link is: `-` for standard input, or
/// a file that holds it.
pub const FLAG: &str = "link";
/// The `--link` value that reads the link from standard input.
const STDIN: &str = "-";
/// The `serve` flag that accepts a different link than the stored one.
pub const REPLACE_FLAG: &str = "replace-link";

#[derive(Clone, PartialEq, Eq)]
pub struct Link(String);

impl fmt::Debug for Link {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str("Link(..)")
	}
}

impl Link {
	/// A link as an operator pastes it. Anything that is not a session link is
	/// refused without echoing it.
	pub fn parse(text: &str) -> Result<Self, Error> {
		let text = text.trim();
		if text.is_empty()
			|| text.len() > MAX_BYTES
			|| glowcap::parse_sturdyref(text, glowcap::CaptpVersion::V1_0).is_err()
		{
			return Err(Error::Config("the value of --link is not a session link".into()));
		}
		Ok(Self(text.to_owned()))
	}

	pub fn as_str(&self) -> &str {
		&self.0
	}

	/// The link `--link` names. A value that is itself a link is refused,
	/// because it already sat on a command line.
	fn given(source: &str) -> Result<Self, Error> {
		if Self::parse(source).is_ok() {
			return Err(Error::Config(
				"--link names where the link is, not the link itself, so the link stays out of the process list. \
				 Pipe it in with --link - or save it to a file and pass that file's path. Then revoke this access, \
				 because its link was on a command line, and issue another"
					.into(),
			));
		}
		let text = if source == STDIN {
			let mut line = String::new();
			std::io::stdin()
				.lock()
				.take(MAX_BYTES as u64 + 1)
				.read_line(&mut line)
				.map_err(Error::io("reading the session link from standard input"))?;
			line
		} else {
			let bytes = storage::read(Path::new(source), MAX_BYTES)?
				.ok_or_else(|| Error::Config(format!("--link names {source}, and there is no such file")))?;
			String::from_utf8(bytes).map_err(|_| Error::Config(format!("{source} is not text")))?
		};
		Self::issued(&text).map_err(|_| Error::Config("what --link names is not a session link".into()))
	}

	/// A link as `session access issue` prints it, a JSON line holding the
	/// link, or the bare link.
	fn issued(text: &str) -> Result<Self, Error> {
		if !text.trim_start().starts_with('{') {
			return Self::parse(text);
		}
		let value: serde_json::Value = serde_json::from_str(text.trim())
			.map_err(|_| Error::Config("the value of --link is not a session link".into()))?;
		Self::parse(
			value
				.get("link")
				.and_then(serde_json::Value::as_str)
				.unwrap_or_default(),
		)
	}

	/// The stored link of a bot directory, read without holding its lease so
	/// the action verbs can run beside `serve`.
	pub fn load(dir: &Path) -> Result<Option<Self>, Error> {
		let bytes = storage::read(&dir.join(FILE), MAX_BYTES)?;
		let Some(bytes) = bytes else {
			return Ok(None);
		};
		let text = String::from_utf8(bytes).map_err(|_| Error::unreadable(FILE, "it is not text"))?;
		Self::parse(&text)
			.map(Some)
			.map_err(|_| Error::unreadable(FILE, "it holds no session link"))
	}

	/// Store the link atomically with owner-only permissions.
	pub fn save(&self, store: &Store) -> Result<(), Error> {
		store.write_bytes(FILE, format!("{}\n", self.0).as_bytes())
	}
}

/// What `serve` does about the link it was given and the one stored.
pub struct Settled {
	pub link: Link,
	/// The link is new or replaces the stored one, so it must be saved.
	pub save: bool,
	/// The stored link this one replaces. Its access settles the lines it sent
	/// before the new link is saved.
	pub replaced: Option<Link>,
}

/// Lay `--link` over the stored link. A first link is taken. The stored link
/// again is a no-op. A different one is refused unless `--replace-link` says
/// the operator means it, because the bot's cursor and ledger belong to the
/// session the old link reached.
pub fn settle(stored: Option<Link>, request: &Request) -> Result<Option<Settled>, Error> {
	let given = request.single(FLAG)?.map(Link::given).transpose()?;
	let replace = request.named.contains_key(REPLACE_FLAG);
	match (stored, given) {
		(None, None) => {
			if replace {
				return Err(Error::Config("--replace-link needs a stored link to replace".into()));
			}
			Ok(None)
		}
		(Some(link), None) if !replace => Ok(Some(Settled {
			link,
			save: false,
			replaced: None,
		})),
		(Some(_), None) => Err(Error::Config("--replace-link needs the new --link".into())),
		(None, Some(link)) if !replace => Ok(Some(Settled {
			link,
			save: true,
			replaced: None,
		})),
		(None, Some(_)) => Err(Error::Config("--replace-link needs a stored link to replace".into())),
		(Some(old), Some(new)) if old == new => Ok(Some(Settled {
			link: old,
			save: false,
			replaced: None,
		})),
		(Some(old), Some(new)) if replace => Ok(Some(Settled {
			link: new,
			save: true,
			replaced: Some(old),
		})),
		(Some(_), Some(_)) => Err(Error::Config(
			"this bot directory already holds a session link. To serve another session, use a new --dir. To move \
			 this bot to a new link for the same session, stop it, pass --replace-link with --link, and revoke the old \
			 access once it serves"
				.into(),
		)),
	}
}

/// A well-formed link that reaches nothing, for tests that need one stored.
#[cfg(test)]
pub const EXAMPLE: &str = "ocapn://wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd.onion/s/eQjP4nR28ffX5eoNCK5DWH6DT_d7BIqD3-My459CUbU";

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_testing::scratch::Scratch;
	use serde_json::json;
	use std::os::unix::fs::PermissionsExt;

	const A: &str = EXAMPLE;
	const B: &str = "ocapn://wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd.onion/s/eQjP4nR28ffX5eoNCK5DWH6DT_d7BIqD3-My459CUbY";

	fn request(named: serde_json::Value) -> Request {
		Request::parse(&json!({"verb":"serve","state":"/d","named":named,"arguments":[]}).to_string()).unwrap()
	}

	#[test]
	fn a_link_is_validated_and_never_printed() {
		assert!(Link::parse(A).is_ok());
		for bad in ["", "hello", &"x".repeat(MAX_BYTES + 1)] {
			let Err(Error::Config(reason)) = Link::parse(bad) else {
				panic!("{bad:?} parsed");
			};
			assert!(!reason.contains(bad) || bad.is_empty(), "{reason}");
		}
		assert!(!format!("{:?}", Link::parse(A).unwrap()).contains("wy46"));
	}

	#[test]
	fn the_stored_link_is_owner_only_and_read_without_the_lease() {
		let dir = Scratch::create("bot-link");
		let store = Store::open(&dir).unwrap();
		Link::parse(A).unwrap().save(&store).unwrap();
		let mode = std::fs::metadata(store.root().join(FILE)).unwrap().permissions().mode();
		assert_eq!(mode & 0o777, 0o600);
		assert_eq!(Link::load(&dir).unwrap(), Some(Link::parse(A).unwrap()));
		std::fs::write(store.root().join(FILE), "garbage").unwrap();
		assert!(matches!(Link::load(&dir), Err(Error::Unreadable { .. })));
	}

	#[test]
	fn a_different_link_needs_the_replace_flag() {
		let scratch = Scratch::create("bot-link-given");
		let (a, b) = (scratch.join("a.link"), scratch.join("b.link"));
		std::fs::write(&a, format!("{A}\n")).unwrap();
		std::fs::write(&b, B).unwrap();
		let (a, b) = (a.to_str().unwrap(), b.to_str().unwrap());
		let stored = || Some(Link::parse(A).unwrap());
		let none = settle(None, &request(json!({}))).unwrap();
		assert!(none.is_none());
		let first = settle(None, &request(json!({"link":[a]}))).unwrap().unwrap();
		assert!(first.save && first.link == Link::parse(A).unwrap());
		let reused = settle(stored(), &request(json!({}))).unwrap().unwrap();
		assert!(!reused.save);
		let same = settle(stored(), &request(json!({"link":[a]}))).unwrap().unwrap();
		assert!(!same.save);
		let refused = settle(stored(), &request(json!({"link":[b]})));
		assert!(
			matches!(&refused, Err(Error::Config(reason)) if reason.contains("--replace-link") && reason.contains("new --dir"))
		);
		let replaced = settle(stored(), &request(json!({"link":[b],"replace-link":["true"]})))
			.unwrap()
			.unwrap();
		assert!(replaced.save && replaced.link == Link::parse(B).unwrap());
		assert!(settle(stored(), &request(json!({"replace-link":["true"]}))).is_err());
	}

	#[test]
	fn what_session_access_issue_prints_is_read_for_its_link() {
		let printed = json!({"ok": true, "id": "ab12", "label": "bot", "link": A}).to_string();
		assert!(Link::issued(&printed).unwrap() == Link::parse(A).unwrap());
		assert!(Link::issued(&format!("{printed}\n")).is_ok());
		assert!(Link::issued(A).is_ok());
		for bad in ["{", "{}", r#"{"link":3}"#, r#"{"link":"nope"}"#] {
			assert!(Link::issued(bad).is_err(), "{bad}");
		}
	}

	#[test]
	fn a_link_on_the_command_line_is_refused_without_echoing_it() {
		let Err(Error::Config(reason)) = settle(None, &request(json!({"link":[EXAMPLE]}))) else {
			panic!("a literal link was accepted");
		};
		assert!(reason.contains("--link -") && !reason.contains("wy46"), "{reason}");
		let missing = settle(None, &request(json!({"link":["/nowhere/at/all"]})));
		assert!(matches!(missing, Err(Error::Config(_))));
	}
}
