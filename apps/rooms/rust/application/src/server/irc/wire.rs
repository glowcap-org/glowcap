//! What a bridged room says to a member's inbox, and the arguments each
//! notice carries: the same `notify` shapes a Rooms room speaks where the
//! vocabulary is shared, and the bridge and seat facts beside them.
use super::seat::{self, View};
use crate::room::{
	carries::{self, Carries},
	inbox::{AUTHORITY_CHANGED, ENDED, ROOM},
	message::LineId,
	subject::Subject,
};
use crate::server::rooms::wire::DataEncoder;
use alloc::{format, string::String, vec::Vec};

/// One thing a bridged room's member hears.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Notice {
	/// A fresh chat line from a member or an IRC name.
	Line {
		from: String,
		text: String,
		/// Its mandatory identity reconciles optimistic sends and admits history.
		line: LineId,
	},
	/// The room's own unmarked announcement.
	Announcement(String),
	Roster {
		said: String,
		names: Vec<String>,
	},
	Join {
		said: String,
		nick: String,
	},
	Leave {
		said: String,
		nick: String,
	},
	Away {
		nick: String,
		why: String,
	},
	/// The channel's topic, which the room tells as its subject's
	/// description. A topic from another network is text, never a link the
	/// room would vouch for, so this subject has none. Told to an arrival, and
	/// announced on change.
	Subject {
		subject: Subject,
		changed: bool,
	},
	/// What a membership here can use: text when the bridge carries lines
	/// back, and never files, previews, or typing, which IRC has no way to
	/// carry. Told first at arrival, ahead of the roster a client returns on.
	Carries(Carries),
	/// The longest line IRC carries from here, said at arrival.
	LineBytes {
		said: String,
		bytes: u64,
	},
	/// The bridge behind this room: the prefix its foreign members carry,
	/// their badge and sentence, and the network as the identity's scope.
	Bridge {
		network: String,
	},
	/// One member's projection onto IRC.
	Seat {
		nick: String,
		view: View,
	},
	Ended(String),
	AuthorityChanged {
		kind: &'static str,
		token: String,
	},
}

impl Notice {
	pub fn room(text: impl Into<String>) -> Self {
		Self::Announcement(text.into())
	}
	/// The display line a notice carries first.
	pub fn said(&self) -> String {
		match self {
			Self::Line { text, .. } => text.clone(),
			Self::Announcement(text) => text.clone(),
			Self::Roster { said, .. }
			| Self::Join { said, .. }
			| Self::Leave { said, .. }
			| Self::LineBytes { said, .. } => said.clone(),
			Self::Away { nick, why } => {
				if why.is_empty() {
					format!("{nick} is back")
				} else {
					format!("{nick} is away: {why}")
				}
			}
			Self::Subject { subject, changed } => subject.said(*changed),
			Self::Ended(reason) => reason.clone(),
			Self::Carries(_) | Self::Bridge { .. } | Self::Seat { .. } | Self::AuthorityChanged { .. } => String::new(),
		}
	}
}

/// The arguments one notice carries on `notify`.
pub fn arguments<E: DataEncoder>(notice: &Notice, e: &mut E) -> Vec<E::Value> {
	let mut out = Vec::new();
	let said = notice.said();
	match notice {
		Notice::Line { from, line, .. } => {
			out.push(e.text(from.clone()));
			out.push(e.text(said));
			out.push(e.text(crate::protocol_data::LINE.into()));
			out.push(e.integer(line.get()));
		}
		Notice::Announcement(_) => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(said));
		}
		Notice::Roster { names, .. } => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(said));
			out.push(e.text(crate::protocol_data::ROSTER.into()));
			for name in names {
				out.push(e.text(name.clone()));
			}
		}
		Notice::Join { nick, .. } | Notice::Leave { nick, .. } => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(said));
			out.push(
				e.text(
					if matches!(notice, Notice::Join { .. }) {
						crate::protocol_data::JOIN
					} else {
						crate::protocol_data::LEAVE
					}
					.into(),
				),
			);
			out.push(e.text(nick.clone()));
		}
		Notice::Away { nick, why } => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(said));
			out.push(e.text(crate::protocol_data::AWAY.into()));
			out.push(e.text(nick.clone()));
			out.push(e.text(why.clone()));
		}
		Notice::Subject { subject, .. } => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(said));
			out.push(e.text(crate::protocol_data::SUBJECT.into()));
			out.push(e.text(subject.description().into()));
		}
		Notice::Carries(carries) => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(String::new()));
			out.push(e.text(carries::TAG.into()));
			for word in carries.words() {
				out.push(e.text(word));
			}
		}
		Notice::LineBytes { bytes, .. } => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(said));
			out.push(e.text(crate::protocol_data::LINE_BYTES.into()));
			out.push(e.integer(*bytes));
		}
		Notice::Bridge { network } => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(String::new()));
			out.push(e.text("bridge".into()));
			out.push(e.text(seat::PREFIX.into()));
			out.push(e.text(seat::FOREIGN_BADGE.into()));
			out.push(e.text(seat::FOREIGN_SAID.into()));
			out.push(e.text(network.clone()));
		}
		Notice::Seat { nick, view } => {
			let (badge, sentence) = seat::words(view);
			out.push(e.text(ROOM.into()));
			out.push(e.text(String::new()));
			out.push(e.text(crate::protocol_data::SEAT.into()));
			out.push(e.text(nick.clone()));
			out.push(e.text(view.phase.wire().into()));
			out.push(e.text(view.nick.clone()));
			out.push(e.text(view.network.clone()));
			out.push(e.text(badge.into()));
			out.push(e.text(sentence));
		}
		Notice::Ended(_) => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(said));
			out.push(e.text(ENDED.into()));
		}
		Notice::AuthorityChanged { kind, token } => {
			out.push(e.text(ROOM.into()));
			out.push(e.text(String::new()));
			out.push(e.text(AUTHORITY_CHANGED.into()));
			out.push(e.text((*kind).into()));
			out.push(e.text(token.clone()));
			out.push(e.boolean(false));
		}
	}
	out
}

#[cfg(test)]
mod tests {
	use super::*;

	#[derive(Debug, PartialEq)]
	enum V {
		T(String),
		I(u64),
		B(bool),
	}
	struct E;
	impl DataEncoder for E {
		type Value = V;
		fn text(&mut self, value: String) -> V {
			V::T(value)
		}
		fn integer(&mut self, value: u64) -> V {
			V::I(value)
		}
		fn boolean(&mut self, value: bool) -> V {
			V::B(value)
		}
	}

	#[test]
	fn seat_and_bridge_facts_take_the_shapes_the_inbox_reads() {
		let line = arguments(
			&Notice::Line {
				from: "alice".into(),
				text: "hello".into(),
				line: LineId::new(7).unwrap(),
			},
			&mut E,
		);
		assert_eq!(
			line,
			[V::T("alice".into()), V::T("hello".into()), V::T("line".into()), V::I(7),]
		);
		assert_eq!(
			arguments(&Notice::room("maintenance"), &mut E),
			[V::T(ROOM.into()), V::T("maintenance".into())]
		);
		let seat = Notice::Seat {
			nick: "alice".into(),
			view: View {
				network: "libera".into(),
				phase: seat::Phase::Linked,
				nick: "al".into(),
			},
		};
		let args = arguments(&seat, &mut E);
		assert_eq!(args[2], V::T("seat".into()));
		assert_eq!(args[4], V::T("linked".into()));
		assert_eq!(args[7], V::T("LINKED".into()));
		assert_eq!(args[8], V::T("Rooms + libera as al".into()));
		let bridge = arguments(
			&Notice::Bridge {
				network: "libera".into(),
			},
			&mut E,
		);
		assert_eq!(bridge[3], V::T("irc/".into()));
		assert_eq!(bridge[6], V::T("libera".into()));
		let bytes = arguments(
			&Notice::LineBytes {
				said: "note".into(),
				bytes: 400,
			},
			&mut E,
		);
		assert_eq!(bytes[3], V::I(400));
		let changed = arguments(
			&Notice::AuthorityChanged {
				kind: "steward",
				token: "t".into(),
			},
			&mut E,
		);
		assert_eq!(changed[5], V::B(false));
		assert_eq!(
			Notice::Away {
				nick: "a".into(),
				why: "".into()
			}
			.said(),
			"a is back"
		);
	}
}
