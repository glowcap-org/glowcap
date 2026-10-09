//! A typing sender holds a source-mediated facet for one exact conversation.
use super::*;

pub struct Typing<D> {
	caller: Caller<D>,
	reference: Ref,
}
impl<D: Deadline + Clone> Workspace<D> {
	/// The current snapshot supplies the selected seat/route coordinate. This
	/// sender never follows a replacement row or substitutes another grant.
	pub async fn typing_sender(&self, conversation: &str, target: custody::Coordinate) -> Result<Typing<D>, Error> {
		if !rooms_application::fields::Text::<1024, true>::accepts_utf16(conversation.encode_utf16())
			|| !matches!(target.role, custody::Role::RoomSeat | custody::Role::DirectAccess)
		{
			return Err(loam::refusal("invalid typing conversation or target").into());
		}
		let snapshot = self.snapshot().await?;
		let source = snapshot
			.intent
			.conversations
			.as_slice()
			.iter()
			.find(|row| row.id().text().as_str() == Some(conversation))
			.and_then(|row| match row {
				workspace::Conversation::Room(row) => row.source,
				workspace::Conversation::Direct(row) => row.source,
			})
			.ok_or_else(|| loam::refusal("typing conversation has no initiating source"))?;
		let source = custody::Coordinate {
			role: custody::Role::SessionAccess,
			key: custody::FieldKey::new(source.slot(), source.generation()),
		};
		let reference = self
			.reader(
				"typing-sender",
				&[
					conversation.into(),
					coordinate_text(target)?.into(),
					coordinate_text(source)?.into(),
				],
			)
			.await?;
		Ok(Typing {
			caller: self.caller.clone(),
			reference,
		})
	}
}
impl<D: Deadline> Typing<D> {
	pub async fn set(&self, on: bool) -> Result<(), Error> {
		let reply = self
			.caller
			.call(
				&self.reference,
				rooms_application::protocol_data::TYPING,
				&[on.into()],
				"the typing target did not answer",
			)
			.await?;
		if reply != Argument::Void {
			return Err(loam::refusal("invalid typing acknowledgment").into());
		}
		Ok(())
	}
}
