//! What a room is about. A subject is a description every client can show,
//! and optionally a link: the sturdyref of an object the room is about,
//! hosted wherever its owner hosts it. The room keeps and repeats both and
//! never calls the link, so what holding the link grants is its host's
//! decision, and whoever sets a subject shares that link with everyone who
//! can read the room.
//!
//! The room never learns what kind of object a link names. A description
//! alone is a whole subject, and a client that cannot use a link still shows
//! the description. An empty description with no link is no subject at all.
//! A link always travels with a description, so every client and every
//! bridge has something to show.
//!
//! The authority to change the subject is a facet a room hands a participant
//! (`setSubject(description, link?)`), and the room announces the subject as
//! `notify("room", said, "subject", description, link?)`.
use alloc::string::String;
use serde::{Deserialize, Deserializer, Serialize, de::Error as _};

/// The longest description, in UTF-16 units. Shorter than a line because a
/// subject is read at a glance, above every message, on a phone as well as
/// a screen. The room bounds only what it keeps, the description and the
/// link. The object behind a link is its host's, and the room never holds it.
pub const MAX_DESCRIPTION: usize = 300;
/// The longest link, in bytes. A sturdyref with routing hints fits well
/// inside it.
pub const MAX_LINK: usize = 1024;
/// The scheme every link carries. The room checks a link's shape, and the
/// host service that accepts `setSubject` parses it as a sturdyref.
pub const LINK_SCHEME: &str = "ocapn://";

/// A room's subject, valid by construction. `T` is the text type: borrowed
/// when read off the wire, owned when held.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Subject<T = String> {
	description: T,
	#[serde(skip_serializing_if = "Option::is_none")]
	link: Option<T>,
}

/// Why a subject was refused. Nothing is trimmed or substituted: a subject is
/// taken exactly or refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Invalid {
	DescriptionLength,
	/// A description is one line of text, so it holds no line break (which
	/// would split it on every client that shows it on one, IRC first) and no
	/// NUL. Other control characters, such as IRC's formatting codes, are
	/// kept, as they are in a line.
	DescriptionLines,
	/// A description that starts with the link scheme would read back as a
	/// link wherever a subject is typed, so it is refused rather than guessed.
	DescriptionStartsWithLink,
	LinkWithoutDescription,
	LinkShape,
	/// A link with a sturdyref's shape that the room's host cannot parse.
	LinkUnreadable,
}

impl core::fmt::Display for Invalid {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::DescriptionLength => write!(f, "a subject's description may be at most {MAX_DESCRIPTION} characters"),
			Self::DescriptionLines => f.write_str("a subject's description must be one line of text"),
			Self::DescriptionStartsWithLink => {
				write!(
					f,
					"a subject's description cannot start with {LINK_SCHEME}, so put the link first"
				)
			}
			Self::LinkWithoutDescription => f.write_str("a subject with a link needs a description"),
			Self::LinkShape => write!(
				f,
				"a subject's link must be an {LINK_SCHEME} sturdyref of at most {MAX_LINK} printable ASCII characters"
			),
			Self::LinkUnreadable => f.write_str("a subject's link is not a sturdyref this room can read"),
		}
	}
}
impl core::error::Error for Invalid {}
impl From<Invalid> for String {
	fn from(invalid: Invalid) -> Self {
		alloc::format!("{invalid}")
	}
}

/// Whether `link` has a sturdyref's outward shape: the OCapN scheme, bounded,
/// and printable ASCII as every URI is, so no space, control, or invisible
/// character can hide in what a reader is offered to copy.
pub fn link_shaped(link: &str) -> bool {
	link.len() > LINK_SCHEME.len()
		&& link.len() <= MAX_LINK
		&& link.starts_with(LINK_SCHEME)
		&& link.bytes().all(|byte| byte.is_ascii_graphic())
}

impl<T: AsRef<str>> Subject<T> {
	/// Take a subject exactly, or refuse it. The empty subject is accepted:
	/// it is how a subject is taken down.
	pub fn new(description: T, link: Option<T>) -> Result<Self, Invalid> {
		let text = description.as_ref();
		if text.encode_utf16().count() > MAX_DESCRIPTION {
			return Err(Invalid::DescriptionLength);
		}
		if text.chars().any(|c| {
			matches!(
				c,
				'\0' | '\n' | '\u{b}' | '\u{c}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
			)
		}) {
			return Err(Invalid::DescriptionLines);
		}
		if text.starts_with(LINK_SCHEME) {
			return Err(Invalid::DescriptionStartsWithLink);
		}
		if let Some(link) = &link {
			if text.is_empty() {
				return Err(Invalid::LinkWithoutDescription);
			}
			if !link_shaped(link.as_ref()) {
				return Err(Invalid::LinkShape);
			}
		}
		Ok(Self { description, link })
	}
	/// No description and no link: the room has no subject.
	pub fn is_empty(&self) -> bool {
		self.description.as_ref().is_empty() && self.link.is_none()
	}
	pub fn description(&self) -> &str {
		self.description.as_ref()
	}
	pub fn link(&self) -> Option<&str> {
		self.link.as_ref().map(AsRef::as_ref)
	}
	/// The room line that tells this subject: to an arrival, or, when
	/// `changed`, to everyone as news. It says whether a link came with the
	/// description, so a change to the link alone still reads as a change.
	pub fn said(&self, changed: bool) -> String {
		if self.is_empty() {
			return "the subject was taken down".into();
		}
		let is = if changed { "is now" } else { "is" };
		let linked = if self.link.is_some() { ", with a link" } else { "" };
		alloc::format!("the subject {is}: {}{linked}", self.description())
	}
	pub fn to_owned(&self) -> Subject {
		Subject {
			description: self.description.as_ref().into(),
			link: self.link.as_ref().map(|link| link.as_ref().into()),
		}
	}
}

impl<'a> Subject<&'a str> {
	/// A subject as a person types it, the one grammar `/subject` and IRC
	/// `TOPIC` read. The whitespace around the text is not part of it. A
	/// leading link word is the link and the words after it describe it, and
	/// any other text is a description alone.
	pub fn typed(text: &'a str) -> Result<Self, Invalid> {
		let white = crate::text::js_whitespace;
		let text = text.trim_matches(white);
		if !text.starts_with(LINK_SCHEME) {
			return Self::new(text, None);
		}
		let (link, rest) = text.split_once(white).unwrap_or((text, ""));
		Self::new(rest.trim_start_matches(white), Some(link))
	}
}

/// A kept subject is read back through the same rules it was written under.
impl<'de> Deserialize<'de> for Subject {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		#[derive(Deserialize)]
		#[serde(deny_unknown_fields)]
		struct Raw {
			description: String,
			#[serde(default)]
			link: Option<String>,
		}
		let raw = Raw::deserialize(d)?;
		Self::new(raw.description, raw.link).map_err(D::Error::custom)
	}
}

impl<T> Subject<T> {
	/// Carry the same text in another type, as a decoded message moves its
	/// borrowed text into owned or interned storage. `f` keeps the text it is
	/// given, so the subject stays valid.
	pub fn map<U>(self, mut f: impl FnMut(T) -> U) -> Subject<U> {
		Subject {
			description: f(self.description),
			link: self.link.map(f),
		}
	}
	pub fn visit(&self, mut f: impl FnMut(&T)) {
		f(&self.description);
		if let Some(link) = &self.link {
			f(link);
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use alloc::{format, string::ToString};

	const LINK: &str = "ocapn://peer.tcp/s/c3dpc3M";

	#[test]
	fn a_description_alone_and_the_empty_subject_are_valid() {
		assert!(!Subject::new("seeds", None).unwrap().is_empty());
		assert!(Subject::new("", None).unwrap().is_empty());
		assert_eq!(Subject::new("", None), Ok(Subject::<&str>::default()));
	}

	#[test]
	fn a_link_needs_a_description_and_a_sturdyref_shape() {
		let linked = |description: &str, link: &str| {
			Subject::new(description.to_string(), Some(link.to_string()))
				.map(|subject| subject.link().map(String::from))
		};
		assert_eq!(linked("board", LINK), Ok(Some(LINK.to_string())));
		assert_eq!(linked("", LINK), Err(Invalid::LinkWithoutDescription));
		for bad in [
			"",
			"ocapn://",
			"https://peer/s/x",
			"ocapn://peer.tcp/s/a b",
			"ocapn://peer.tcp/s/a\nb",
			"ocapn://peer.tcp/s/a\u{202e}b",
			"ocapn://peer.tcp/s/a\u{200b}b",
		] {
			assert_eq!(linked("board", bad), Err(Invalid::LinkShape), "{bad:?}");
		}
		let longest = format!("{LINK_SCHEME}{}", "a".repeat(MAX_LINK - LINK_SCHEME.len()));
		assert!(linked("board", &longest).is_ok());
		assert_eq!(linked("board", &format!("{longest}a")), Err(Invalid::LinkShape));
	}

	#[test]
	fn a_kept_subject_reads_back_only_under_its_rules() {
		let kept: Subject =
			serde_json::from_str(r#"{"description":"board","link":"ocapn://peer.tcp/s/c3dpc3M"}"#).unwrap();
		assert_eq!(kept.link(), Some(LINK));
		assert_eq!(
			serde_json::to_string(&kept).unwrap(),
			r#"{"description":"board","link":"ocapn://peer.tcp/s/c3dpc3M"}"#
		);
		assert_eq!(
			serde_json::to_string(&Subject::new("seeds", None).unwrap()).unwrap(),
			r#"{"description":"seeds"}"#
		);
		assert!(serde_json::from_str::<Subject>(r#"{"description":"","link":"ocapn://peer.tcp/s/c3dpc3M"}"#).is_err());
		assert!(serde_json::from_str::<Subject>(r#"{"description":"board","extra":1}"#).is_err());
	}

	#[test]
	fn a_typed_subject_reads_one_way_only() {
		assert_eq!(Subject::typed("seeds and soil"), Subject::new("seeds and soil", None));
		assert_eq!(Subject::typed(""), Ok(Subject::default()));
		assert_eq!(Subject::typed(" \u{a0}seeds\t"), Subject::new("seeds", None));
		assert_eq!(Subject::typed("  "), Ok(Subject::default()));
		assert_eq!(
			Subject::typed(" ocapn://peer.tcp/s/c3dpc3M the board"),
			Subject::new("the board", Some(LINK))
		);
		assert_eq!(
			Subject::typed("ocapn://peer.tcp/s/c3dpc3M  the board "),
			Subject::new("the board", Some(LINK))
		);
		assert_eq!(Subject::typed(LINK), Err(Invalid::LinkWithoutDescription));
		// The scheme is exact, so another case is a description.
		assert!(Subject::typed("OCAPN://peer the board").unwrap().link().is_none());
		// No description reads back as a link, from any door.
		assert_eq!(
			Subject::new("ocapn://peer the board", None),
			Err(Invalid::DescriptionStartsWithLink)
		);
		assert_eq!(
			Subject::new("ocapn://elsewhere", Some(LINK)),
			Err(Invalid::DescriptionStartsWithLink)
		);
	}

	#[test]
	fn a_subject_is_said_with_whether_it_links() {
		let linked = Subject::new("the board", Some(LINK)).unwrap();
		assert_eq!(linked.said(true), "the subject is now: the board, with a link");
		assert_eq!(
			Subject::new("seeds", None).unwrap().said(false),
			"the subject is: seeds"
		);
		assert_eq!(Subject::<&str>::default().said(true), "the subject was taken down");
	}

	#[test]
	fn a_description_is_one_line() {
		for bad in [
			"a\nb",
			"a\rb",
			"a\u{b}b",
			"a\u{c}b",
			"a\u{0}b",
			"a\u{85}b",
			"a\u{2028}b",
			"a\u{2029}b",
		] {
			assert_eq!(Subject::new(bad, None), Err(Invalid::DescriptionLines), "{bad:?}");
		}
		// IRC's bold and colour codes, and a tab, stay on one line.
		assert!(Subject::new("a b · ü 😀\u{2}bold\u{2} \u{3}4red\u{f}\tend", None).is_ok());
	}

	#[test]
	fn a_description_is_measured_in_utf16_units() {
		assert!(Subject::new("a".repeat(MAX_DESCRIPTION), None).is_ok());
		assert_eq!(
			Subject::new("a".repeat(MAX_DESCRIPTION + 1), None),
			Err(Invalid::DescriptionLength)
		);
		assert_eq!(
			Subject::new("😀".repeat(MAX_DESCRIPTION / 2 + 1), None),
			Err(Invalid::DescriptionLength)
		);
	}
}
