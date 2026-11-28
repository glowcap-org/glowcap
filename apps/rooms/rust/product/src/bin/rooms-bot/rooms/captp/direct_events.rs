//! An activity read checks each original inbox on the session owner. Bracket
//! that check with the posting route before attaching its identity to a DM.
use super::*;
use crate::bot::rooms::Scope;
use std::collections::BTreeMap;

pub(super) fn peers(raw: &attached::Batch) -> Vec<&attached::Event> {
	raw.events
		.iter()
		.filter(|event| {
			let attached::Notice::Line(line) = &event.notice else {
				return false;
			};
			event.conversation.kind == attached::Kind::Direct
				&& line.id.is_some()
				&& line.from.is_none()
				&& line.change == attached::Change::Said
		})
		.collect()
}

use crate::bot::rooms::{Cursor, Opening, Sender};
use rooms_application::direct::RECIPROCAL_ROUTE_TIMEOUT_MS;

pub(super) async fn admitted(
	live: &Live,
	before: &attached::Snapshot,
	peers: &[&attached::Event],
) -> Result<BTreeMap<String, Sender>, attached::Error> {
	let mut senders = BTreeMap::new();
	for event in peers {
		let id = event.conversation.id.as_str();
		let sender = Scope::held(&live.grant, id, before)
			.map(Sender::DirectPeer)
			.or_else(|| {
				let scope = Scope::opening(&live.grant, id, before)?;
				let until = crate::bot::stamp::seconds().saturating_add(RECIPROCAL_ROUTE_TIMEOUT_MS.div_ceil(1000));
				Some(Sender::OpeningPeer(scope, until))
			});
		if let Some(sender) = sender
			&& live.view.still_presents(&event.cursor, &event.conversation).await?
		{
			senders.insert(event.cursor.clone(), sender);
		}
	}
	if !senders.is_empty() {
		let after = live.view.posting_snapshot().await?;
		senders.retain(|_, sender| match sender {
			Sender::DirectPeer(scope) => scope.matches(&live.grant, &after),
			Sender::OpeningPeer(scope, _) => {
				scope.matches(&live.grant, &after)
					|| Scope::opening(&live.grant, scope.conversation(), &after).as_ref() == Some(scope)
			}
			_ => false,
		});
	}
	Ok(senders)
}

/// Only an actual held route plus the original re-presented inbound messages
/// can promote a pending turn. Rechecking the snapshot fences replacements
/// that occurred while the reader was presenting the events.
pub(super) async fn opening(live: &Live, scope: &Scope, events: &[Cursor]) -> Result<Opening, attached::Error> {
	let before = live.view.posting_snapshot().await?;
	if scope.matches(&live.grant, &before) {
		let conversation = attached::Conversation {
			kind: attached::Kind::Direct,
			id: scope.conversation().into(),
		};
		for event in events {
			if !live.view.still_presents(event.as_str(), &conversation).await? {
				return Ok(Opening::Gone);
			}
		}
		let after = live.view.posting_snapshot().await?;
		return Ok(if scope.matches(&live.grant, &after) {
			Opening::Held
		} else {
			Opening::Gone
		});
	}
	Ok(
		if Scope::opening(&live.grant, scope.conversation(), &before).as_ref() == Some(scope) {
			Opening::Pending
		} else {
			Opening::Gone
		},
	)
}
