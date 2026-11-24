//! The session link the bot attaches with. It is a capability: whoever holds
//! it holds the access it was issued with. So it lives in its own owner-only
//! file in the bot directory, and nothing here prints it. A [`Link`] has no
//! `Display`, its `Debug` hides the text, and a refusal never quotes it. It
//! arrives on standard input or in a file, never as a command-line value,
//! because every process on the machine can read a command line. What it
//! holds may be the bare link or the JSON line `session access issue` prints.
use super::{
	error::{Error, LinkStage},
	request::Request,
	store::Store,
};
use rooms_platform::storage;
use std::{fmt, io::BufRead, path::Path};

pub const FILE: &str = "session.link";
/// The longest link, or `issue` line holding one, the bot reads. Both are one line.
const MAX_BYTES: usize = 4096;
/// The `serve` flag that names where the link is: `-` for standard input, or
/// a file that holds it.
pub const FLAG: &str = "link";
/// The `--link` value that reads the link from standard input.
const STDIN: &str = "-";
/// What the operator does to serve a session other than the stored one.
const ANOTHER_SESSION: &str = "To serve another session, use a new --dir.";
/// The `serve` flag that accepts a different link than the stored one.
pub const REPLACE_FLAG: &str = "replace-link";

#[derive(Clone, PartialEq, Eq)]
pub struct Link(String);

impl fmt::Debug for Link {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str("Link(..)")
	}
}

/// The first line of `reader`, at most [`MAX_BYTES`] long. A longer one is
/// refused as too long, because a link and the line `issue` prints around it
/// are shorter, and "not a session link" would blame the wrong thing.
fn bounded_line(reader: impl BufRead) -> Result<String, Error> {
	let mut line = String::new();
	reader
		.take(MAX_BYTES as u64 + 1)
		.read_line(&mut line)
		.map_err(Error::io("reading the session link from standard input"))?;
	if line.trim_end().len() > MAX_BYTES {
		return Err(Error::Config(format!(
			"what --link - read is longer than the {MAX_BYTES} bytes a session link and its issue line hold"
		)));
	}
	Ok(line)
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

	/// Whether both links reach one session. The transport and designator name
	/// the session's peer, and the hints are only advice for dialing it, which
	/// may differ between two issues. Every access to a session has its own
	/// swiss number, so those differ.
	pub fn same_session(&self, other: &Self) -> bool {
		let peer = |link: &Self| {
			glowcap::parse_sturdyref(&link.0, glowcap::CaptpVersion::V1_0)
				.map(|r| (r.locator.transport, r.locator.designator))
		};
		matches!((peer(self), peer(other)), (Ok(a), Ok(b)) if a == b)
	}

	pub fn as_str(&self) -> &str {
		&self.0
	}

	/// The link `--link` names. A value that is itself a link, bare or as the
	/// JSON line `issue` prints, is refused, because it already sat on a
	/// command line or a variable. No error here repeats the value, which may
	/// hold a link.
	fn given(source: &str) -> Result<Self, Error> {
		if Self::issued(source).is_ok() {
			return Err(Error::Config(
				"--link, or the variable that stands for it, names where the link is, not the link itself, so the \
				 link stays out of the process list and the environment. Pipe it in with --link - or save it to a \
				 file and pass that file's path. Then revoke this access, because its link was passed as a flag or \
				 variable value, and issue another"
					.into(),
			));
		}
		let text = if source == STDIN {
			bounded_line(std::io::stdin().lock())?
		} else {
			// The cause is the system's words for the failure, never the file's content.
			let unread = |cause| Error::Config(format!("--link names a file that cannot be read: {cause}"));
			let bytes = storage::read(Path::new(source), MAX_BYTES)
				.map_err(unread)?
				.ok_or_else(|| {
					Error::Config(
						"--link is neither a session link nor a file that exists. Pass `-` to read the link from \
						 standard input, or the path of a file that holds it"
							.into(),
					)
				})?;
			String::from_utf8(bytes).map_err(|_| Error::Config("the file --link names is not text".into()))?
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

/// What `serve` does about the link it was given and the one stored. The
/// stage says which, and only a replacement holds the link it replaces.
pub struct Linking {
	stage: LinkStage,
	link: Link,
	replaced: Option<Link>,
}

impl Linking {
	/// The stored link again, which is already saved.
	fn stored(link: Link) -> Self {
		Self {
			stage: LinkStage::Stored,
			link,
			replaced: None,
		}
	}

	/// A first link, saved once the session has answered it.
	fn first(link: Link) -> Self {
		Self {
			stage: LinkStage::First,
			link,
			replaced: None,
		}
	}

	/// A link for the same session that replaces the stored one `old`, whose
	/// access settles the lines it sent before the new link is saved.
	fn replacing(new: Link, old: Link) -> Self {
		Self {
			stage: LinkStage::Replacing,
			link: new,
			replaced: Some(old),
		}
	}

	/// The link this start serves with.
	pub fn link(&self) -> &Link {
		&self.link
	}

	/// Which link the session is asked to accept, as a refusal words it.
	pub fn stage(&self) -> LinkStage {
		self.stage
	}

	/// The stored link a replacement replaces.
	pub fn replaced(&self) -> Option<&Link> {
		self.replaced.as_ref()
	}
}

/// Lay `--link` over the stored link. A first link is taken. The stored link
/// again is a no-op. A different one is refused unless `--replace-link` says
/// the operator means it, because the bot's cursor and ledger belong to the
/// session the old link reached.
pub fn resolve(stored: Option<Link>, request: &Request) -> Result<Option<Linking>, Error> {
	let given = request.single(FLAG)?.map(Link::given).transpose()?;
	let replace = request.named.contains_key(REPLACE_FLAG);
	match (stored, given) {
		(None, None) => {
			if replace {
				return Err(Error::Config("--replace-link needs a stored link to replace".into()));
			}
			Ok(None)
		}
		(Some(link), None) if !replace => Ok(Some(Linking::stored(link))),
		(Some(_), None) => Err(Error::Config("--replace-link needs the new --link".into())),
		(None, Some(link)) if !replace => Ok(Some(Linking::first(link))),
		(None, Some(_)) => Err(Error::Config("--replace-link needs a stored link to replace".into())),
		(Some(old), Some(new)) if old == new => Ok(Some(Linking::stored(old))),
		(Some(old), Some(new)) if replace => {
			if !old.same_session(&new) {
				return Err(Error::Config(format!(
					"--link reaches a different session than the stored link. The bot's place in the session belongs \
					 to the session it first reached. {ANOTHER_SESSION}"
				)));
			}
			Ok(Some(Linking::replacing(new, old)))
		}
		(Some(_), Some(_)) => Err(Error::Config(format!(
			"this bot directory already holds a session link. {ANOTHER_SESSION} To move this bot to a new link for \
			 the same session, stop it, pass --replace-link with --link, and revoke the old access once it serves"
		))),
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

	/// The flag and the variable that stands for it share one refusal, so the
	/// refusal names both places and does not echo the value.
	#[test]
	fn a_link_given_as_the_value_is_refused_naming_both_places_it_could_have_been() {
		let Err(Error::Config(reason)) = Link::given(A) else {
			panic!("a link given as the value was accepted");
		};
		assert!(reason.contains("variable") && !reason.contains(A), "{reason}");
	}

	#[test]
	fn a_line_past_the_bound_is_refused_as_too_long_and_one_at_it_is_read() {
		let at = format!("{}\n", "x".repeat(MAX_BYTES));
		assert_eq!(bounded_line(at.as_bytes()).unwrap(), at);
		let past = format!("{}\n", "x".repeat(MAX_BYTES + 1));
		let Err(Error::Config(reason)) = bounded_line(past.as_bytes()) else {
			panic!("a line past the bound was read");
		};
		assert!(reason.contains("longer than"), "{reason}");
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
	fn a_replacement_is_refused_for_another_session_and_accepted_for_another_access_to_the_same_one() {
		const OTHER_PEER: &str = "ocapn://peer.tcp/s/Ym9hcmQ";
		let scratch = Scratch::create("bot-link-sessions");
		let file = |name: &str, text: &str| {
			let path = scratch.join(name);
			std::fs::write(&path, text).unwrap();
			path.to_str().unwrap().to_owned()
		};
		let (other, same) = (file("other.link", OTHER_PEER), file("same.link", B));
		let replace = |link: &str| {
			resolve(
				Some(Link::parse(A).unwrap()),
				&request(json!({"link":[link],"replace-link":["true"]})),
			)
		};
		let refused = replace(&other);
		assert!(
			matches!(&refused, Err(Error::Config(reason)) if reason.contains("different session")),
			"{:?}",
			refused.as_ref().err()
		);
		let accepted = replace(&same).unwrap().unwrap();
		assert_eq!(accepted.stage(), LinkStage::Replacing);
		assert!(accepted.replaced() == Some(&Link::parse(A).unwrap()));
	}

	#[test]
	fn a_different_link_needs_the_replace_flag() {
		let scratch = Scratch::create("bot-link-given");
		let (a, b) = (scratch.join("a.link"), scratch.join("b.link"));
		std::fs::write(&a, format!("{A}\n")).unwrap();
		std::fs::write(&b, B).unwrap();
		let (a, b) = (a.to_str().unwrap(), b.to_str().unwrap());
		let stored = || Some(Link::parse(A).unwrap());
		let none = resolve(None, &request(json!({}))).unwrap();
		assert!(none.is_none());
		let first = resolve(None, &request(json!({"link":[a]}))).unwrap().unwrap();
		assert_eq!(first.stage(), LinkStage::First);
		assert!(*first.link() == Link::parse(A).unwrap());
		let reused = resolve(stored(), &request(json!({}))).unwrap().unwrap();
		assert_eq!(reused.stage(), LinkStage::Stored);
		let same = resolve(stored(), &request(json!({"link":[a]}))).unwrap().unwrap();
		assert_eq!(same.stage(), LinkStage::Stored);
		let refused = resolve(stored(), &request(json!({"link":[b]})));
		assert!(
			matches!(&refused, Err(Error::Config(reason)) if reason.contains("--replace-link") && reason.contains("new --dir"))
		);
		let replaced = resolve(stored(), &request(json!({"link":[b],"replace-link":["true"]})))
			.unwrap()
			.unwrap();
		assert_eq!(replaced.stage(), LinkStage::Replacing);
		assert!(*replaced.link() == Link::parse(B).unwrap());
		assert!(resolve(stored(), &request(json!({"replace-link":["true"]}))).is_err());
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
		let Err(Error::Config(reason)) = resolve(None, &request(json!({"link":[EXAMPLE]}))) else {
			panic!("a literal link was accepted");
		};
		assert!(reason.contains("--link -") && !reason.contains("wy46"), "{reason}");
		let wrapped = json!({"link": EXAMPLE}).to_string();
		let Err(Error::Config(reason)) = resolve(None, &request(json!({"link":[wrapped]}))) else {
			panic!("a JSON-wrapped link was accepted");
		};
		assert!(!reason.contains("ocapn:") && !reason.contains("wy46"), "{reason}");
		let missing = resolve(None, &request(json!({"link":["/nowhere/at/all"]})));
		let Err(Error::Config(reason)) = missing else {
			panic!("a missing file was accepted");
		};
		assert!(!reason.contains("/nowhere"), "{reason}");
	}

	#[test]
	fn a_link_file_that_cannot_be_read_says_why_without_its_content() {
		let dir = Scratch::create("bot-link-unreadable");
		let file = dir.join("link");
		std::fs::write(&file, EXAMPLE).unwrap();
		std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o000)).unwrap();
		if std::fs::read(&file).is_ok() {
			return; // a user that ignores file modes cannot be refused
		}
		let named = json!({"link":[file.to_str().unwrap()]});
		let Err(Error::Config(reason)) = resolve(None, &request(named)) else {
			panic!("an unreadable file was accepted");
		};
		assert!(
			reason.contains("cannot be read: ") && reason.to_lowercase().contains("permission denied"),
			"{reason}"
		);
		assert!(!reason.contains("wy46"), "{reason}");
	}
}
