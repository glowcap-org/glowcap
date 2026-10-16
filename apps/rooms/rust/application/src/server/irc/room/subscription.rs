//! Reader replacement commits before effects run, preserving feed demand.
use super::*;
use crate::room::carries::Carries;

impl<C: Copy + Ord, R: Clone> Room<C, R> {
	/// Seat one reader. `seat_view` is the gateway's projection of each
	/// member, replayed to the arrival.
	#[allow(clippy::too_many_arguments)]
	pub fn subscribe(
		&mut self,
		connection: C,
		nick: &str,
		inbox: R,
		kind: MembershipKind,
		subscribe_note: &str,
		line_bytes: u64,
		seat_view: &dyn Fn(C) -> Option<View>,
	) -> Result<Effects<C, R>, Refusal> {
		self.admit_reader(connection, nick)?;
		let mut effects = Effects::default();
		effects.presence.push(connection);
		let old = self.members.insert(
			connection,
			Member {
				nick: nick.into(),
				inbox,
				away: String::new(),
				kind,
			},
		);
		if let Some(old) = old {
			effects.releases.push((connection, old.inbox));
			if old.nick != nick || old.kind != kind {
				self.tell_all(
					&mut effects,
					Notice::Leave {
						said: format!("{} changed membership", old.nick),
						nick: old.nick,
					},
				);
			}
		}
		effects.relay.extend(self.relay.set_readers(self.members.len()));
		self.tell_all(
			&mut effects,
			Notice::Join {
				said: format!("{nick} joined ({} here)", self.count()),
				nick: nick.into(),
			},
		);
		// What the room carries goes ahead of the roster a client returns on,
		// so its surface is shaped before anybody can type into it. IRC keeps
		// no link previews and relays no typing, whichever way the bridge runs.
		self.tell_one(&mut effects, connection, Notice::Carries(Carries::NOTHING));
		self.tell_one(
			&mut effects,
			connection,
			Notice::LineBytes {
				said: subscribe_note.into(),
				bytes: line_bytes,
			},
		);
		// Before the roster, always: the next line names members whose rows
		// only mean something once a reader knows which names are not this
		// room's own.
		self.tell_one(
			&mut effects,
			connection,
			Notice::Bridge {
				network: self.network.clone(),
			},
		);
		self.tell_one(
			&mut effects,
			connection,
			Notice::Roster {
				said: "who is here".into(),
				names: self.visible_nicks(),
			},
		);
		for (seated, member) in &self.members {
			if member.kind != MembershipKind::Participant {
				continue;
			}
			if let Some(view) = seat_view(*seated) {
				self.tell_one(
					&mut effects,
					connection,
					Notice::Seat {
						nick: member.nick.clone(),
						view,
					},
				);
			}
		}
		if !self.subject.is_empty() {
			self.tell_one(
				&mut effects,
				connection,
				Notice::Subject {
					subject: self.subject.clone(),
					changed: false,
				},
			);
		}
		for (seated, member) in &self.members {
			if member.away.is_empty() || *seated == connection {
				continue;
			}
			self.tell_one(
				&mut effects,
				connection,
				Notice::Away {
					nick: member.nick.clone(),
					why: member.away.clone(),
				},
			);
		}
		effects.count_changed = true;
		Ok(effects)
	}
}
