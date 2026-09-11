//! Capability and receipt custody for a consumable room invitation.
use super::{Client, Deadline, Entropy, Error};
use glowcap::{Argument, Ref};
use rooms_application::room::invitation::{self, Receipt};

pub struct Invitation<D> {
	client: Client<D>,
	reference: Ref,
	receipt: Receipt,
}
impl<D: Deadline + Entropy> Invitation<D> {
	/// Adopt a received invitation. Entropy failure releases the adopted handle;
	/// no claim has been sent and no remote authority has been consumed.
	pub fn new(client: Client<D>, reference: Ref) -> Result<Self, Error> {
		let receipt = client.deadline.invitation_receipt()?;
		Ok(Self::with_receipt(client, reference, receipt))
	}
}
impl<D: Deadline> Invitation<D> {
	pub(super) fn with_receipt(client: Client<D>, reference: Ref, receipt: Receipt) -> Self {
		Self {
			client,
			reference,
			receipt,
		}
	}
	pub fn reference(&self) -> &Ref {
		&self.reference
	}
	pub async fn claim(&self) -> Result<Ref, Error> {
		let answer = self
			.client
			.ask(
				&self.reference,
				invitation::CLAIM,
				&[self.receipt.as_str()],
				"the room invitation did not answer its claim",
			)
			.await?;
		match answer.0 {
			Argument::Reference(entrance) => Ok(entrance),
			_ => Err(invitation::Error::Entrance.into()),
		}
	}
}
