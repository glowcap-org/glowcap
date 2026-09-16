//! What a room carries: the parts of a message it keeps or relays that no
//! capability stands for.
//!
//! What a member may *do* in a room is what they hold: a participant seat
//! posts where an observer seat cannot, the topic authority is a facet the
//! room hands over or withholds, and so is the files facet. Those are
//! authority, and a client draws its controls from holding them. Two things
//! are not authority but description: whether the room keeps the link
//! previews a line names, and whether it relays the typing signal. A bridge
//! to IRC does neither, and nothing a member holds could say so, so the room
//! states it once on the same structured tail its other standing facts ride,
//! as `notify("room", "", "carries", ...features)`. It is said at arrival,
//! before the roster, so a client holds it by the time joining returns.
//!
//! The vocabulary is positive. A feature named is carried; one not named is
//! not; one a reader does not know is skipped. A room that never states the
//! fact has not said it lacks anything, and a reader keeps every control it
//! has, so an older room loses nothing and a newer one can be exact.
use alloc::{string::String, vec::Vec};
use serde::{Deserialize, Serialize};

/// The tag on the room line that states what the room carries.
pub use crate::protocol_data::CARRIES as TAG;
/// The most features one statement may name, and the longest name. Both are
/// bounds on a peer's line rather than on this vocabulary, which is shorter.
pub const MAX_FEATURES: usize = 16;
pub const MAX_FEATURE_BYTES: usize = 16;

/// One thing a room may carry, in the word the wire uses for it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Feature {
	/// The link previews a line keeps, the `postWithPreviews` verbs. A room
	/// that does not carry them takes the plain `post`, and a composer does
	/// not offer previews it would only drop.
	Previews,
	/// The ephemeral typing signal, relayed to the other members.
	Typing,
	/// Correlated receipts and reuse of acknowledged upload storage.
	Retained,
}
impl Feature {
	pub const ALL: [Self; 3] = [Self::Previews, Self::Typing, Self::Retained];
	pub const fn wire(self) -> &'static str {
		match self {
			Self::Previews => "previews",
			Self::Typing => "typing",
			Self::Retained => "retained",
		}
	}
	pub fn parse(word: &str) -> Option<Self> {
		Self::ALL.into_iter().find(|feature| feature.wire() == word)
	}
}

/// What one room carries. JSON views expose the displayed features; delivery
/// negotiation stays with the live membership that received the wire facts.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Carries {
	pub previews: bool,
	pub typing: bool,
	/// Transport optimization, not a displayed room feature.
	#[serde(skip)]
	pub retained: bool,
}
impl Carries {
	/// Everything this vocabulary names: what a native room carries.
	pub const EVERYTHING: Self = Self {
		previews: true,
		typing: true,
		retained: true,
	};
	/// Nothing: what a room bridged to IRC carries beyond its lines.
	pub const NOTHING: Self = Self {
		previews: false,
		typing: false,
		retained: false,
	};
	pub const fn has(self, feature: Feature) -> bool {
		match feature {
			Feature::Previews => self.previews,
			Feature::Typing => self.typing,
			Feature::Retained => self.retained,
		}
	}
	/// The features carried, in the wire's order.
	pub fn features(self) -> impl Iterator<Item = Feature> {
		Feature::ALL.into_iter().filter(move |feature| self.has(*feature))
	}
	/// The wire words, ready for a notice.
	pub fn words(self) -> Vec<String> {
		self.features().map(|feature| feature.wire().into()).collect()
	}
	/// Read a statement off its wire words. A word this vocabulary does not
	/// know is skipped, so a room may state a feature before every reader
	/// learns it. A statement past the bounds, or one carrying something that
	/// is not a word, is a room saying something malformed, and the honest
	/// reading of that is that it said nothing.
	pub fn read<'a>(words: impl ExactSizeIterator<Item = Option<&'a str>>) -> Option<Self> {
		if words.len() > MAX_FEATURES {
			return None;
		}
		let mut carries = Self::default();
		for word in words {
			let word = word.filter(|word| !word.is_empty() && word.len() <= MAX_FEATURE_BYTES)?;
			match Feature::parse(word) {
				Some(Feature::Previews) => carries.previews = true,
				Some(Feature::Typing) => carries.typing = true,
				Some(Feature::Retained) => carries.retained = true,
				None => {}
			}
		}
		Some(carries)
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use alloc::vec;

	#[test]
	fn a_statement_round_trips_through_its_words() {
		for carries in [Carries::EVERYTHING, Carries::NOTHING] {
			let words = carries.words();
			let read = Carries::read(words.iter().map(|word| Some(word.as_str()))).unwrap();
			assert_eq!(read, carries);
		}
		assert_eq!(Carries::EVERYTHING.words(), ["previews", "typing", "retained"]);
		assert!(Carries::NOTHING.words().is_empty());
	}

	#[test]
	fn an_unknown_word_is_skipped_and_a_malformed_statement_is_nothing() {
		let read = Carries::read([Some("typing"), Some("holograms")].into_iter()).unwrap();
		assert_eq!(
			read,
			Carries {
				previews: false,
				typing: true,
				retained: false
			}
		);
		assert_eq!(Carries::read([Some("typing"), None].into_iter()), None, "not a word");
		assert_eq!(Carries::read([Some("")].into_iter()), None, "an empty word");
		let long = "x".repeat(17);
		assert_eq!(Carries::read([Some(long.as_str())].into_iter()), None, "past the bound");
		let many = vec![Some("typing"); MAX_FEATURES + 1];
		assert_eq!(Carries::read(many.into_iter()), None, "too many words");
	}
}
