//! Tolerant display metadata. Unknown or malformed facts leave display text intact.
use super::super::{message::LineId, ArgumentView};
use alloc::{boxed::Box, vec::Vec};
use serde::Serialize;

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Presence<T> {
	Roster { names: Vec<T> },
	Join { name: T },
	Leave { name: T },
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
	pub topic: Option<T>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub line_bytes: Option<u64>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub listed: Option<bool>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub bridge: Option<Box<Bridge<T>>>,
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
		"roster" => Presence::Roster {
			names: args[3..]
				.iter()
				.filter_map(|a| a.text().filter(|s| bounded(s, 32)))
				.collect(),
		},
		"join" => Presence::Join {
			name: text(args, 3, 32, false)?,
		},
		"leave" => Presence::Leave {
			name: text(args, 3, 32, false)?,
		},
		"away" => Presence::Away {
			name: args.get(3)?.text()?,
			reason: args.get(4).and_then(ArgumentView::text).unwrap_or(""),
		},
		"seat" => {
			let state = args.get(4)?.text()?;
			if !matches!(state, "rooms" | "connecting" | "linked" | "failed") {
				return None;
			}
			Presence::Seat(Box::new(Seat {
				name: text(args, 3, 32, false)?,
				state,
				nick: text(args, 5, 32, false)?,
				network: text(args, 6, 32, false)?,
				badge: text(args, 7, 12, true)?,
				said: text(args, 8, 120, true)?,
			}))
		}
		_ => return None,
	})
}
pub fn facts<A: ArgumentView>(args: &[A]) -> Option<Facts<&str>> {
	let tag = args.get(2)?.text()?;
	let mut facts = Facts {
		topic: None,
		line_bytes: None,
		listed: None,
		bridge: None,
	};
	match tag {
		"topic" => facts.topic = Some(text(args, 3, 300, false)?),
		"line-bytes" => facts.line_bytes = Some(LineId::read(args.get(3)?)?.get()),
		"listed" => facts.listed = Some(true),
		"unlisted" => facts.listed = Some(false),
		"bridge" => {
			facts.bridge = Some(Box::new(Bridge {
				prefix: text(args, 3, 12, true)?,
				badge: text(args, 4, 12, true)?,
				said: text(args, 5, 120, true)?,
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
			Self::Roster { names } => names.iter().for_each(f),
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
			topic: self.topic.map(&mut f),
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
		}
	}
	pub fn visit(&self, mut f: impl FnMut(&T)) {
		if let Some(t) = &self.topic {
			f(t);
		}
		if let Some(b) = &self.bridge {
			for t in [&b.prefix, &b.badge, &b.said, &b.scope] {
				f(t);
			}
		}
	}
}
