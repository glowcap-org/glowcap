//! Tolerant display metadata. Unknown or malformed facts leave display text intact.
use super::super::{
	ArgumentView,
	carries::{self, Carries},
	message::LineId,
	subject::Subject,
};
use alloc::{boxed::Box, vec::Vec};
use serde::Serialize;

pub const MAX_SEAT_PREFIX: usize = 12;
pub const MAX_SEAT_BADGE: usize = 12;
pub const MAX_SEAT_SAID: usize = 120;

/// A notification has one metadata tag. Local receipt correlation occupies
/// the same slot, keeping mutually exclusive details out of ordinary lines.
#[derive(Debug)]
pub enum Metadata<T> {
	Presence(Presence<T>),
	Facts(Facts<T>),
	Receipt(u64),
	Operation(T),
}
impl<T> Metadata<T> {
	pub fn map<U>(self, mut f: impl FnMut(T) -> U) -> Metadata<U> {
		match self {
			Self::Presence(value) => Metadata::Presence(value.map(f)),
			Self::Facts(value) => Metadata::Facts(value.map(&mut f)),
			Self::Receipt(request) => Metadata::Receipt(request),
			Self::Operation(operation) => Metadata::Operation(f(operation)),
		}
	}
}

pub(super) fn read<A: ArgumentView>(args: &[A]) -> Option<Metadata<&str>> {
	presence(args)
		.map(Metadata::Presence)
		.or_else(|| facts(args).map(Metadata::Facts))
}

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Presence<T> {
	Roster { names: Vec<T> },
	Join { name: T },
	Leave { name: T },
	Offline { names: Vec<T> },
	Away { name: T, reason: T },
	// Keep bridge-only seat details out of every ordinary queued line.
	Seat(Box<Seat<T>>),
}
#[derive(Debug, Serialize)]
pub struct Seat<T> {
	pub name: T,
	pub state: T,
	pub nick: T,
	pub network: T,
	pub badge: T,
	pub said: T,
}
#[derive(Debug, Serialize)]
pub struct Bridge<T> {
	pub prefix: T,
	pub badge: T,
	pub said: T,
	pub scope: T,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Facts<T> {
	#[serde(skip_serializing_if = "Option::is_none")]
	pub subject: Option<Box<Subject<T>>>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub line_bytes: Option<u64>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub listed: Option<bool>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub bridge: Option<Box<Bridge<T>>>,
	/// See `crate::room::carries`. What a membership here can use.
	#[serde(skip_serializing_if = "Option::is_none")]
	pub carries: Option<Carries>,
}
pub(super) fn bounded(text: &str, max: usize) -> bool {
	text.encode_utf16().take(max + 1).count() <= max
}
fn text<A: ArgumentView>(args: &[A], at: usize, max: usize, nonempty: bool) -> Option<&str> {
	args.get(at)?
		.text()
		.filter(|s| (!nonempty || !s.is_empty()) && bounded(s, max))
}
pub fn presence<A: ArgumentView>(args: &[A]) -> Option<Presence<&str>> {
	let tag = args.get(2)?.text()?;
	Some(match tag {
		crate::protocol_data::ROSTER => Presence::Roster {
			names: args[3..]
				.iter()
				.filter_map(|a| a.text().filter(|s| bounded(s, 32)))
				.collect(),
		},
		crate::protocol_data::JOIN => Presence::Join {
			name: text(args, 3, 32, false)?,
		},
		crate::protocol_data::LEAVE => Presence::Leave {
			name: text(args, 3, 32, false)?,
		},
		crate::protocol_data::OFFLINE if args.len() - 3 <= crate::server::rooms::MAX_ROOM_OFFLINE => {
			Presence::Offline {
				names: args[3..]
					.iter()
					.map(|a| a.text().filter(|s| !s.is_empty() && bounded(s, 32)))
					.collect::<Option<Vec<_>>>()?,
			}
		}
		crate::protocol_data::AWAY => Presence::Away {
			name: args.get(3)?.text()?,
			reason: args.get(4).and_then(ArgumentView::text).unwrap_or(""),
		},
		crate::protocol_data::SEAT => {
			let state = args.get(4)?.text()?;
			if !matches!(state, "rooms" | "connecting" | "linked" | "failed") {
				return None;
			}
			Presence::Seat(Box::new(Seat {
				name: text(args, 3, 32, false)?,
				state,
				nick: text(args, 5, 32, false)?,
				network: text(args, 6, 32, false)?,
				badge: text(args, 7, MAX_SEAT_BADGE, true)?,
				said: text(args, 8, MAX_SEAT_SAID, true)?,
			}))
		}
		_ => return None,
	})
}
pub fn facts<A: ArgumentView>(args: &[A]) -> Option<Facts<&str>> {
	let tag = args.get(2)?.text()?;
	let mut facts = Facts {
		subject: None,
		line_bytes: None,
		listed: None,
		bridge: None,
		carries: None,
	};
	match tag {
		carries::TAG => facts.carries = Some(Carries::read(args[3..].iter().map(ArgumentView::text))?),
		crate::protocol_data::SUBJECT if args.len() <= 5 => {
			let link = args
				.get(4)
				.map(|link| link.text())
				.map_or(Some(None), |link| link.map(Some))?;
			facts.subject = Some(Box::new(Subject::new(args.get(3)?.text()?, link).ok()?));
		}
		crate::protocol_data::LINE_BYTES => facts.line_bytes = Some(LineId::read(args.get(3)?)?.get()),
		crate::protocol_data::LISTED => facts.listed = Some(true),
		crate::protocol_data::UNLISTED => facts.listed = Some(false),
		"bridge" => {
			facts.bridge = Some(Box::new(Bridge {
				prefix: text(args, 3, MAX_SEAT_PREFIX, true)?,
				badge: text(args, 4, MAX_SEAT_BADGE, true)?,
				said: text(args, 5, MAX_SEAT_SAID, true)?,
				scope: text(args, 6, 64, true)?,
			}))
		}
		_ => return None,
	}
	Some(facts)
}
impl<T> Presence<T> {
	pub fn map<U>(self, mut f: impl FnMut(T) -> U) -> Presence<U> {
		match self {
			Self::Roster { names } => Presence::Roster {
				names: names.into_iter().map(f).collect(),
			},
			Self::Join { name } => Presence::Join { name: f(name) },
			Self::Leave { name } => Presence::Leave { name: f(name) },
			Self::Offline { names } => Presence::Offline {
				names: names.into_iter().map(f).collect(),
			},
			Self::Away { name, reason } => Presence::Away {
				name: f(name),
				reason: f(reason),
			},
			Self::Seat(seat) => {
				let Seat {
					name,
					state,
					nick,
					network,
					badge,
					said,
				} = *seat;
				Presence::Seat(Box::new(Seat {
					name: f(name),
					state: f(state),
					nick: f(nick),
					network: f(network),
					badge: f(badge),
					said: f(said),
				}))
			}
		}
	}
	pub fn visit(&self, mut f: impl FnMut(&T)) {
		match self {
			Self::Roster { names } | Self::Offline { names } => names.iter().for_each(f),
			Self::Join { name } | Self::Leave { name } => f(name),
			Self::Away { name, reason } => {
				f(name);
				f(reason);
			}
			Self::Seat(s) => {
				for t in [&s.name, &s.state, &s.nick, &s.network, &s.badge, &s.said] {
					f(t);
				}
			}
		}
	}
}
impl<T> Facts<T> {
	pub fn map<U>(self, mut f: impl FnMut(T) -> U) -> Facts<U> {
		Facts {
			subject: self.subject.map(|subject| Box::new((*subject).map(&mut f))),
			line_bytes: self.line_bytes,
			listed: self.listed,
			bridge: self.bridge.map(|b| {
				Box::new(Bridge {
					prefix: f(b.prefix),
					badge: f(b.badge),
					said: f(b.said),
					scope: f(b.scope),
				})
			}),
			carries: self.carries,
		}
	}
	pub fn visit(&self, mut f: impl FnMut(&T)) {
		if let Some(subject) = &self.subject {
			subject.visit(&mut f);
		}
		if let Some(b) = &self.bridge {
			for t in [&b.prefix, &b.badge, &b.said, &b.scope] {
				f(t);
			}
		}
	}
}
