//! Direct callbacks and reciprocal routes select exact saved source custody.
use super::*;

pub(super) fn install(
	intent: &mut workspace::Intent,
	id: &workspace::Id,
	next: custody::FieldKey<custody::DirectInbox>,
) -> Result<Option<custody::Coordinate>> {
	let row = intent
		.conversations
		.as_mut_slice()
		.iter_mut()
		.find_map(|row| match row {
			workspace::Conversation::Direct(row) if row.id == *id => Some(row),
			_ => None,
		})
		.ok_or_else(|| refuse("direct conversation was retired"))?;
	Ok(row
		.inbox
		.replace(next)
		.map(|key| coordinate(custody::Role::DirectInbox, key)))
}

impl<P: Tasks + Deadline + Clone + 'static> Session<P> {
	pub async fn direct_source(&self, row: &workspace::Direct) -> Result<Source<P>> {
		if row.closed {
			return Err(refuse("direct conversation is closed"));
		}
		self.realization_source(Selection::Direct {
			id: row.id.clone(),
			directory: row.directory.clone(),
			peer: row.peer.clone(),
			access: row.access,
			introduction: row.introduction.clone(),
			inbox: row.inbox,
			source: row
				.source
				.ok_or_else(|| refuse("direct conversation has no initiating source"))?,
		})
		.await
	}
}
impl<P: Deadline + Clone> Source<P> {
	pub async fn announce_direct(
		&self,
		operation: &str,
		inbox: custody::FieldKey<custody::DirectInbox>,
	) -> Result<Operation<P>> {
		if !matches!(self.selection, Selection::Direct { inbox: Some(selected), .. } if selected == inbox) {
			return Err(refuse("direct readiness requires the installed inbox"));
		}
		let snapshot = self.snapshot().await?;
		let verb = match &self.selection {
			Selection::Direct { access: Some(_), .. } => "directReady",
			Selection::Direct {
				access: None,
				introduction: Some(_),
				..
			} => "offerDirectInbox",
			_ => return Err(refuse("direct receiver has neither a route nor an exact introduction")),
		};
		let command = self
			.workspace
			.prepare_command(
				operation,
				snapshot.revision,
				verb,
				&[
					self.selection
						.id()
						.text()
						.as_str()
						.ok_or_else(|| refuse("invalid direct ID"))?
						.into(),
					encoded(&inbox)?,
				],
			)
			.await
			.map_err(|e| refuse(&e.to_string()))?;
		Ok(Operation {
			command,
			selection: self.selection.clone(),
		})
	}
}
