//! Shared consumers parse the domain protocol after managed callback admission.
//! Event custody retains the original source, files, offers and direct line owner.
use super::{Activity, Event, History, PreparedEvent};
use crate::session::managed::{
	LineMemory, LineReceiver, LineResize, MembershipEvent, MembershipReceiver, MembershipTarget,
};
use glowcap::{Argument, Ref};
use rooms_application::{
	content::session::custody,
	direct,
	directory::registration,
	room::{
		attachment::Attachment,
		inbox,
		line::{LineChange, Proposal},
	},
};
use rooms_glowcap::client::{Deadline, Tasks};
use rooms_glowcap::{
	Value,
	client::direct::received_line::{self, Changes},
};
use serde_json::{Value as Json, json};
use std::rc::{Rc, Weak};

pub(super) fn receiver<P: Tasks + Deadline + Clone + 'static>(
	target: MembershipTarget,
	owner: Weak<crate::session::managed::State<P>>,
	events: Weak<Activity<P>>,
	lines: Rc<LineReceiver<P>>,
) -> MembershipReceiver {
	Box::new(move |event| match event {
		MembershipEvent::DirectorySnapshot { snapshot, origin } => {
			events.upgrade().ok_or("Session activity has closed")?.push(Event {
				history: History::None.into(),
				data: envelope(&target, json!({"kind":"discoverySnapshot","snapshot":snapshot})),
				origin: origin.clone().into(),
				files: Vec::new(),
				incoming: None,
				line: None,
				charge: None,
			})?;
			Ok(Argument::Void)
		}
		MembershipEvent::DirectoryChanged { event, origin } => {
			events.upgrade().ok_or("Session activity has closed")?.push(Event {
				history: History::None.into(),
				data: envelope(&target, json!({"kind":"discoveryChanged","event":event})),
				origin: origin.clone().into(),
				files: Vec::new(),
				incoming: None,
				line: None,
				charge: None,
			})?;
			Ok(Argument::Void)
		}
		MembershipEvent::Notification { arguments, origin } => {
			let values = rooms_glowcap::values(arguments).collect::<Vec<_>>();
			let mut files = Vec::new();
			let mut recorded = None;
			let notice = match &target {
				MembershipTarget::Discovery(_) => return Err("discovery needs its observation consumer".into()),
				MembershipTarget::Directory(_) => {
					match registration::notice("notify", |at| arguments.get(at).map(Value))
						.map_err(|e| e.to_string())?
					{
						Some(registration::Notice::Registered { nick, id }) => {
							json!({"kind":"registered", "nick":nick, "registration":id.as_str()})
						}
						Some(registration::Notice::Event(event)) => {
							if event.kind == registration::Kind::MintInboxFor {
								crate::session::managed::introductions::accept(&owner, origin, &event)
									.map_err(|e| e.to_string())?;
							}
							json!({"kind":match event.kind {
						registration::Kind::MintInboxFor => "mintInboxFor",
						registration::Kind::DirectRequested => "directRequested",
						registration::Kind::Introducible => "introducible",
					}, "peer":event.peer, "registration":event.registration.as_str(), "opening":event.opening})
						}
						None => return Ok(Argument::Void),
					}
				}
				MembershipTarget::Room(_) => match inbox::read("notify", &values).map_err(|e| e.to_string())? {
					inbox::Notice::Line(line) => {
						recorded = line.marker.and_then(|marker| {
							super::super::recording::record(
								&owner,
								origin,
								&super::super::recording::Line {
									from: line.from,
									text: line.text,
									previews: &line.previews,
									id: marker.id,
									change: marker.kind,
									system: line.from == inbox::ROOM,
								},
								&line.attachments,
							)
						});
						let metadata = match &line.metadata {
							Some(inbox::metadata::Metadata::Presence(value)) => json!({"presence":value}),
							Some(inbox::metadata::Metadata::Facts(value)) => json!({"facts":value}),
							Some(inbox::metadata::Metadata::Receipt(value)) => json!({"receipt":value.to_string()}),
							None => json!(null),
						};
						files = line.attachments;
						json!({"kind":"line", "from":line.from, "text":line.text,
							"marker":line.marker.map(|marker| json!({"id":marker.id.get(), "change":marker.kind.event_change()})),
							"metadata":metadata,
							"previewUrls":line.previews.urls()})
					}
					inbox::Notice::Ended(reason) => json!({"kind":"ended", "reason":reason}),
					inbox::Notice::Typing { name, on } => json!({"kind":"typing", "name":name, "on":on}),
					inbox::Notice::Policy(policy) => json!({"kind":"policy", "policy":policy}),
					inbox::Notice::Occupancy { listed, claimable } => {
						json!({"kind":"occupancy", "listed":listed, "claimable":claimable})
					}
					inbox::Notice::Authority { kind, token, claimable } => {
						json!({"kind":"authority", "authority":match kind {
						rooms_application::room::stewardship::Kind::Room => "room",
						rooms_application::room::stewardship::Kind::Steward => "steward",
						rooms_application::room::stewardship::Kind::Manager => "manager",
					}, "token":token, "claimable":claimable})
					}
				},
				MembershipTarget::Direct(_) => return Err("direct notification needs its protocol consumer".into()),
			};
			events.upgrade().ok_or("Session activity has closed")?.push(Event {
				history: recorded.map_or(History::None, History::Recorded).into(),
				data: envelope(&target, notice),
				origin: origin.clone().into(),
				files,
				incoming: None,
				line: None,
				charge: None,
			})?;
			Ok(Argument::Void)
		}
		MembershipEvent::Direct {
			verb,
			arguments,
			delivering: _,
			origin,
		} => {
			let origin = origin.clone();
			let mut fields = [Value(&Argument::Void); direct::MAX_ARGUMENTS];
			for (field, argument) in fields.iter_mut().zip(arguments) {
				*field = Value(argument);
			}
			let notice =
				direct::read(verb, &fields[..arguments.len().min(direct::MAX_ARGUMENTS)]).map_err(|e| e.to_string())?;
			// Managed forwarding can deliver this callback in a local turn. The
			// reciprocal capability still names its actual exporter; a nickname
			// lookup or the directory connection cannot identify that channel.
			let reply = match &notice {
				direct::Notice::Ready(reference) => Some(reference),
				direct::Notice::Message { reply, .. } => reply.as_ref(),
				_ => None,
			};
			let session = match (reply, owner.upgrade()) {
				(Some(reference), Some(owner)) => owner
					.writer
					.host
					.reference_session(reference)
					.map_err(|error| error.to_string())?,
				_ => None,
			};
			if let Some(session) = session
				&& let Some((rooms_application::content::session::workspace::InboxSelection::Direct { peer, .. }, _)) =
					origin.installed()
			{
				glowcap::annotate_session(&session, peer.text().as_str());
			}
			let mut files = Vec::new();
			let mut incoming = None;
			let mut retained = None;
			let mut answer = Argument::Void;
			let mut recorded = None;
			let data = match notice {
				direct::Notice::Message {
					text,
					reply,
					previews,
					attachments,
				} => {
					let MembershipTarget::Direct(id) = &target else {
						return Err("direct target required".into());
					};
					let bytes = line_bytes::<P>(id, attachments.iter()) + previews.retained_bytes();
					let line = lines
						.receive(origin.clone(), bytes, |line, memory| {
							received_line::behavior(
								line,
								id.clone(),
								attachments.clone(),
								|| true,
								LineChanges {
									owner: owner.clone(),
									events: events.clone(),
									target: target.clone(),
									origin: origin.clone(),
									memory,
									previews: previews.clone(),
								},
							)
						})
						.map_err(|e| e.to_string())?;
					let marker = line.id().get();
					let from = origin
						.installed()
						.and_then(|(selection, _)| match selection {
							rooms_application::content::session::workspace::InboxSelection::Direct { peer, .. } => {
								peer.text().as_str()
							}
							_ => None,
						})
						.unwrap_or("");
					recorded = super::super::recording::record(
						&owner,
						&origin,
						&super::super::recording::Line {
							from,
							text,
							previews: &previews,
							id: line.id(),
							change: rooms_application::room::message::ChangeKind::Said,
							system: false,
						},
						&attachments,
					);
					answer = line.reference().clone().into();
					retained = Some(Rc::new(line));
					incoming = reply.map(|reference| super::Incoming::Hand(custody::Role::DirectAccess, reference));
					files = attachments;
					json!({"kind":"line", "text":text, "marker":{"id":marker, "change":"said"}, "previewUrls":previews.urls()})
				}
				direct::Notice::Typing(on) => json!({"kind":"typing", "on":on}),
				direct::Notice::Ready(reference) => {
					crate::session::managed::introductions::route(&owner, &origin, &reference)
						.map_err(|e| e.to_string())?;
					json!({"kind":"ready"})
				}
				direct::Notice::HandRoom { label, room } => {
					incoming = Some(super::Incoming::Hand(custody::Role::RoomAccess, room));
					json!({"kind":"handRoom", "label":label})
				}
				direct::Notice::OfferRoom { label, link } => {
					incoming = Some(super::Incoming::offer(custody::Role::RoomAccess, link)?);
					json!({"kind":"offerRoom", "label":label})
				}
				direct::Notice::HandArchive {
					directory,
					kind,
					conversation,
					archive,
				} => {
					incoming = Some(super::Incoming::Hand(custody::Role::ArchiveAccess, archive));
					json!({"kind":"handArchive", "directory":directory, "scope":kind.wire(), "conversation":conversation})
				}
				direct::Notice::OfferArchive {
					directory,
					kind,
					conversation,
					link,
				} => {
					incoming = Some(super::Incoming::offer(custody::Role::ArchiveAccess, link)?);
					json!({"kind":"offerArchive", "directory":directory, "scope":kind.wire(), "conversation":conversation})
				}
			};
			let activity = events.upgrade().ok_or("Session activity has closed")?;
			let rollback = retained.clone();
			if let Err(error) = activity.push(Event {
				history: recorded.map_or(History::None, History::Recorded).into(),
				data: envelope(&target, data),
				origin: origin.clone().into(),
				files,
				incoming,
				line: retained,
				charge: None,
			}) {
				if let Some(line) = rollback {
					line.retire();
				}
				return Err(error);
			}
			Ok(answer)
		}
	})
}
fn envelope(target: &MembershipTarget, notice: Json) -> String {
	let (kind, id) = match target {
		MembershipTarget::Discovery(id) => ("discovery", id),
		MembershipTarget::Directory(id) => ("directory", id),
		MembershipTarget::Room(id) => ("room", id),
		MembershipTarget::Direct(id) => ("direct", id),
	};
	json!({"target":{"kind":kind,"id":id},"notice":notice}).to_string()
}
pub(super) fn history_data(history: rooms_application::archive::Coordinates) -> Json {
	json!({"source":history.source,"generation":history.generation,"id":history.id})
}
fn line_bytes<'a, P: Tasks + Deadline + Clone + 'static>(
	id: &str,
	files: impl Iterator<Item = &'a Attachment<Ref>>,
) -> usize {
	2 * id.len()
		+ size_of::<LineChanges<P>>()
		+ size_of::<rooms_application::room::line::Line<Attachment<Ref>>>()
		+ files
			.map(|file| size_of::<Attachment<Ref>>() + file.description.retained_bytes())
			.sum::<usize>()
}
struct LineChanges<P: Tasks + Deadline + Clone + 'static> {
	owner: Weak<crate::session::managed::State<P>>,
	events: Weak<Activity<P>>,
	target: MembershipTarget,
	origin: crate::session::managed::InboxOrigin,
	memory: LineMemory,
	previews: rooms_application::open_graph::Selection,
}
impl<P: Tasks + Deadline + Clone + 'static> Changes for LineChanges<P> {
	type Reservation = (LineResize, PreparedEvent<P>, rooms_application::open_graph::Selection);
	fn reserve(&mut self, proposal: Proposal<'_, Attachment<Ref>>) -> Result<Self::Reservation, String> {
		let MembershipTarget::Direct(id) = &self.target else {
			unreachable!("direct line")
		};
		let previews = if proposal.kind == rooms_application::room::message::ChangeKind::Withdrawn {
			Default::default()
		} else {
			self.previews.retained_for(proposal.text)
		};
		let memory = self
			.memory
			.prepare(line_bytes::<P>(id, proposal.files()) + proposal.from.len() + previews.retained_bytes())
			.map_err(|e| e.to_string())?;
		let event = Event {
			history: if self.origin.recording_destination().is_some() {
				History::Reserved
			} else {
				History::None
			}
			.into(),
			data: envelope(
				&self.target,
				json!({"kind":"line", "text":proposal.text,
			"marker":{"id":proposal.id.get(),"change":proposal.kind.event_change()}, "previewUrls":previews.urls()}),
			),
			origin: self.origin.clone().into(),
			files: proposal.files().cloned().collect(),
			incoming: None,
			line: None,
			charge: None,
		};
		let activity = self.events.upgrade().ok_or("Session activity has closed")?;
		Ok((memory, activity.prepare(event, false)?, previews))
	}
	fn commit(&mut self, (memory, event, previews): Self::Reservation, change: LineChange<'_, '_, Attachment<Ref>>) {
		memory.commit();
		self.previews = previews;
		let from = self
			.origin
			.installed()
			.and_then(|(selection, _)| match selection {
				rooms_application::content::session::workspace::InboxSelection::Direct { peer, .. } => {
					peer.text().as_str()
				}
				_ => None,
			})
			.unwrap_or("");
		let history = super::super::recording::record(
			&self.owner,
			&self.origin,
			&super::super::recording::Line {
				from,
				text: change.text,
				previews: &self.previews,
				id: change.id,
				change: change.kind,
				system: false,
			},
			&event.event.files,
		);
		*event.event.history.borrow_mut() = history.map_or(History::None, History::Recorded);
		if change.kind == rooms_application::room::message::ChangeKind::Withdrawn {
			event.activity.withdraw(change.id.get());
		}
		event.commit();
	}
}
