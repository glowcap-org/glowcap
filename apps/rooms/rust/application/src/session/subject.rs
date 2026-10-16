//! A room's subject as the attached session keeps and carries it. The
//! description is document text, so a browser's text (a lone UTF-16
//! surrogate included) survives exactly, and the subject keeps every rule
//! `crate::room::subject` states. A link is a sturdyref, so it is always
//! well-formed Unicode.
use crate::{fields::Text, room::subject, text::DocumentText};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "Raw")]
pub struct Subject {
	description: Text<{ subject::MAX_DESCRIPTION }>,
	#[serde(skip_serializing_if = "Option::is_none")]
	link: Option<Text<{ subject::MAX_LINK }, true>>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Raw {
	description: Text<{ subject::MAX_DESCRIPTION }>,
	#[serde(default)]
	link: Option<Text<{ subject::MAX_LINK }, true>>,
}

impl TryFrom<Raw> for Subject {
	type Error = subject::Invalid;
	fn try_from(raw: Raw) -> Result<Self, Self::Error> {
		let link = match &raw.link {
			None => None,
			Some(link) => Some(link.text().as_str().ok_or(subject::Invalid::LinkShape)?),
		};
		// A lone surrogate stays one UTF-16 unit when read lossily, so the
		// description is measured exactly.
		subject::Subject::new(raw.description.text().utf8_lossy().as_ref(), link)?;
		Ok(Self {
			description: raw.description,
			link: raw.link,
		})
	}
}

impl Subject {
	/// The subject a room stated, which its reader already validated.
	pub fn from_room<T: AsRef<str>>(stated: &subject::Subject<T>) -> Option<Self> {
		Some(Self {
			description: Text::new(stated.description().into())?,
			link: match stated.link() {
				None => None,
				Some(link) => Some(Text::new(link.into())?),
			},
		})
	}
	pub fn description(&self) -> &DocumentText {
		self.description.text()
	}
	pub fn link(&self) -> Option<&str> {
		self.link.as_ref().and_then(|link| link.text().as_str())
	}
	pub(crate) fn heap_bytes(&self) -> usize {
		self.description.text().heap_bytes() + self.link.as_ref().map_or(0, |link| link.text().heap_bytes())
	}
}
