use super::*;
use rooms_application::room::{authority, invitation, queries};

impl<D: Deadline> Client<D> {
	pub async fn room_manager_identity(&self, reference: &Ref) -> Result<String, Error> {
		let reply = self
			.call(
				reference,
				authority::MANAGED_IDENTITY,
				&[],
				"the room did not identify its manager",
			)
			.await?;
		authority::management_identity(&reply)?;
		let Argument::String(identity) = reply.0 else {
			unreachable!("management identity validated scalar text")
		};
		Ok(identity)
	}

	pub async fn room_called(&self, reference: &Ref) -> Result<String, Error> {
		let answer = self
			.call(
				reference,
				queries::CALLED,
				&[],
				"the room did not say what it is called",
			)
			.await?;
		Ok(queries::called(&Value(&answer.0)).into())
	}
	pub async fn room_is_private(&self, reference: &Ref) -> Result<bool, Error> {
		let answer = self
			.call(
				reference,
				queries::PRIVATE,
				&[],
				"the room did not say whether it is listed",
			)
			.await?;
		Ok(queries::is_private(&Value(&answer.0))?)
	}
	pub async fn room_policy(&self, reference: &Ref) -> Result<RoomPolicy, Error> {
		let answer = self
			.call(reference, queries::POLICY, &[], "the room did not answer its policy")
			.await?;
		Ok(queries::policy(&answer)?)
	}
}
impl<D: Deadline + Tasks + Clone + 'static> Room<D> {
	pub async fn called(&self) -> Result<String, Error> {
		self.inner.client.room_called(&self.inner.reference).await
	}
	pub async fn is_private(&self) -> Result<bool, Error> {
		self.inner.client.room_is_private(&self.inner.reference).await
	}
	pub async fn policy(&self) -> Result<RoomPolicy, Error> {
		self.inner.client.room_policy(&self.inner.reference).await
	}
}
impl<D: Deadline + Tasks + Entropy + Clone + 'static> Room<D> {
	pub async fn invite(&self, kind: MembershipKind) -> Result<super::super::invitation::Invitation<D>, Error> {
		let seat = self.seat()?;
		// Reserve the claim receipt before the mint effect. Entropy failure must
		// not leave a live remote invitation that the caller never receives.
		let receipt = self.inner.client.deadline.invitation_receipt()?;
		let answer = self
			.inner
			.client
			.ask(
				&seat,
				invitation::MINT,
				&[kind.as_str()],
				"the membership did not answer an invitation",
			)
			.await?;
		match answer.0 {
			Argument::Reference(reference) => Ok(super::super::invitation::Invitation::with_receipt(
				self.inner.client.clone(),
				reference,
				receipt,
			)),
			_ => Err(invitation::Error::Invitation.into()),
		}
	}
}
