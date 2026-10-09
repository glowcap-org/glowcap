//! A delegated line capability. Its owner is independent of the membership
//! that posted it; dropping the handle releases its application retain.
use super::{Client, Deadline, Error, Reply};
use glowcap::{Argument, Ref};

/// Room posts return their authoritative line identity with the capability.
/// Direct inboxes return a capability; their sender owns its local line ID.
/// This borrows the reply and never duplicates capability custody.
pub fn reply(value: &Argument) -> glowcap::Result<(Option<&Ref>, Option<rooms_application::room::message::LineId>)> {
	match value {
		Argument::Void => Ok((None, None)),
		Argument::Reference(reference) => Ok((Some(reference), None)),
		Argument::List(parts) => {
			let [id, authority] = parts.as_slice() else {
				return Err(glowcap::loam::refusal("invalid posted line reply"));
			};
			let id = id
				.as_i64()
				.and_then(|id| u64::try_from(id).ok())
				.and_then(rooms_application::room::message::LineId::new)
				.ok_or_else(|| glowcap::loam::refusal("invalid posted line identity"))?;
			let authority = match authority {
				Argument::Reference(reference) => Some(reference),
				Argument::Void => None,
				_ => return Err(glowcap::loam::refusal("invalid posted line authority")),
			};
			Ok((authority, Some(id)))
		}
		_ => Err(glowcap::loam::refusal("invalid posted line reply")),
	}
}

pub struct PostedLine<D> {
	client: Client<D>,
	reference: Ref,
	id: Option<rooms_application::room::message::LineId>,
}
impl<D: Deadline> PostedLine<D> {
	/// Adopt an existing owned capability, including one handed to this caller.
	pub fn new(client: Client<D>, reference: Ref) -> Self {
		Self {
			client,
			reference,
			id: None,
		}
	}
	pub fn id(&self) -> Option<rooms_application::room::message::LineId> {
		self.id
	}
	pub fn reference(&self) -> &Ref {
		&self.reference
	}
	pub async fn edit(&self, text: &str) -> Result<(), Error> {
		self.client
			.ask(
				&self.reference,
				rooms_application::protocol_data::EDIT,
				&[text],
				"the room did not answer changing that line",
			)
			.await?;
		Ok(())
	}
	/// Keep selected files and adopt files already staged by this caller.
	/// The host owns index validation against the line's current files.
	pub async fn refile(&self, caption: &str, keep: &[u32]) -> Result<(), Error> {
		let pending = {
			let mut args = Vec::with_capacity(1 + keep.len());
			args.push(Argument::String(caption.into()));
			args.extend(keep.iter().map(|&index| Argument::Integer(index.into())));
			self.client.call(
				&self.reference,
				rooms_application::protocol_data::REFILE,
				&args,
				"the line's host did not answer changing its files",
			)
		};
		pending.await?;
		Ok(())
	}
	/// Idempotence is the line host's authority. Each call observes its result.
	pub async fn withdraw(&self) -> Result<(), Error> {
		self.client
			.call(
				&self.reference,
				rooms_application::protocol_data::WITHDRAW,
				&[],
				"the room did not answer taking that line back",
			)
			.await?;
		Ok(())
	}
}
impl<D> PostedLine<D> {
	pub(super) fn from_reply(client: Client<D>, reply: Reply) -> Option<Self> {
		let (_, id) = self::reply(&reply.0).ok()?;
		match reply.0 {
			Argument::Reference(reference) => Some(Self { client, reference, id }),
			Argument::List(mut parts) => match parts.pop()? {
				Argument::Reference(reference) => Some(Self { client, reference, id }),
				_ => None,
			},
			_ => None,
		}
	}
	pub(super) fn from_room_reply(client: Client<D>, reply: Reply) -> Result<Option<Self>, Error> {
		if matches!(reply.0, Argument::Reference(_)) {
			return Err(glowcap::loam::refusal("room post omitted its line identity").into());
		}
		self::reply(&reply.0)?;
		Ok(Self::from_reply(client, reply))
	}
}

impl<D: Deadline + super::Tasks + Clone + 'static> PostedLine<D> {
	/// Direct lines accept new files inline, under fresh one-pass grants.
	pub async fn refile_files(
		&self,
		caption: &str,
		keep: &[u32],
		owner: &super::sources::Sources<D>,
		files: Vec<super::sources::Source>,
	) -> Result<(), Error> {
		let mut leading = Vec::with_capacity(1 + keep.len());
		leading.push(Argument::String(caption.into()));
		leading.extend(keep.iter().map(|&index| Argument::Integer(index.into())));
		owner
			.send(
				&self.client,
				&self.reference,
				rooms_application::protocol_data::REFILE,
				leading,
				files,
			)
			.await?;
		Ok(())
	}
}
