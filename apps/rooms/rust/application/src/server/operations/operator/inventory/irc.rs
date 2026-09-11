//! IRC publications and their retained membership inboxes in the operator's
//! shared inventory. Acts keep publication and membership incarnations.
use super::*;
use crate::server::operations::faces::StewardshipRow;
pub struct Member<C> {
	pub id: u64,
	pub connection: C,
	pub nick: String,
	pub state: String,
}
pub struct Face<C> {
	pub stewardship: StewardshipRow,
	pub steward_token: Option<String>,
	pub origin: String,
	pub members: Vec<Member<C>>,
}
impl<C: Copy + Ord, R: Clone> View<'_, C, R> {
	pub(super) fn irc_sources(&self, category: Category, kind: Option<ReferenceKind>) -> Vec<Source<Row, Act>> {
		let mut out = Vec::new();
		for bridge in &self.irc {
			let id = &bridge.stewardship.name;
			let name = &bridge.stewardship.label;
			match category {
				Category::Stewardships => out.push(Source {
					text: search_text(&[id, name, "listed"]),
					row: Row::Stewardship(bridge.stewardship.clone()),
					retire: bridge.steward_token.as_ref().map(|token| Act::RevokeIrcSteward {
						publication: id.clone(),
						token: token.clone(),
					}),
				}),
				Category::Rooms => {
					let mut parts = alloc::vec![id.as_str(), name.as_str(), "irc", bridge.origin.as_str()];
					parts.extend(bridge.members.iter().map(|member| member.nick.as_str()));
					out.push(Source {
						text: search_text(&parts),
						retire: Some(Act::RemoveIrc(id.clone())),
						row: Row::Room {
							id: id.clone(),
							kind: RoomKind::Irc,
							name: name.clone(),
							origin: bridge.origin.clone(),
							proof: "bridge",
							retained: Some(bridge.members.len() as u64),
							members_more: bridge.members.len() > MAX_MEMBERS_PER_ROOM,
							members: bridge
								.members
								.iter()
								.take(MAX_MEMBERS_PER_ROOM)
								.map(|member| {
									(
										member.nick.clone(),
										self.session_id(member.connection).unwrap_or("").into(),
										member.state.clone(),
									)
								})
								.collect(),
						},
					});
				}
				Category::References if kind.is_none_or(|kind| kind == ReferenceKind::Membership) => {
					for member in bridge.members.iter().rev() {
						let reference = alloc::format!("ref-irc-{id}-{}", member.id);
						out.push(Source {
							text: search_text(&[
								&reference,
								"membership",
								"IRC room membership",
								name,
								&member.nick,
								"membership inbox",
							]),
							row: Row::Reference {
								id: reference,
								kind: ReferenceKind::Membership,
								owner: "IRC room membership",
								room: name.clone(),
								member: member.nick.clone(),
								detail: "membership inbox".into(),
							},
							retire: Some(Act::EndIrcMembership {
								publication: id.clone(),
								membership: member.id,
							}),
						});
					}
				}
				_ => {}
			}
		}
		out
	}
}
