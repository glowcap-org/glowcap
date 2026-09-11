//! A delegated line capability. Its owner is independent of the membership
//! that posted it; dropping the handle releases its application retain.
use super::{Client, Deadline, Error, Reply};
use glowcap::{Argument, Ref};

pub struct PostedLine<D> {
	client: Client<D>,
	reference: Ref,
}
impl<D: Deadline> PostedLine<D> {
	/// Adopt an existing owned capability, including one handed to this caller.
	pub fn new(client: Client<D>, reference: Ref) -> Self {
		Self { client, reference }
	}
	pub fn reference(&self) -> &Ref {
		&self.reference
	}
	pub async fn edit(&self, text: &str) -> Result<(), Error> {
		self.client
			.ask(
				&self.reference,
				"edit",
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
				"refile",
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
				"withdraw",
				&[],
				"the room did not answer taking that line back",
			)
			.await?;
		Ok(())
	}
}
impl<D> PostedLine<D> {
	pub(super) fn from_reply(client: Client<D>, reply: Reply) -> Option<Self> {
		match reply.0 {
			Argument::Reference(reference) => Some(Self { client, reference }),
			_ => None,
		}
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
			.send(&self.client, &self.reference, "refile", leading, files)
			.await?;
		Ok(())
	}
}
