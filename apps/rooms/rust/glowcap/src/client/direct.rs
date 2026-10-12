//! Direct capability calls and the shared inbox receiver over actual turn context.
pub mod publisher;
pub mod received_line;
use super::posted_line::PostedLine;
use super::*;
use crate::Value;
use rooms_application::{archive::ShareKind, direct as policy};

/// The receiver chooses which sibling verbs it supports and returns their real
/// outcome. Deferred durable work must use the Host resolver, not an early ack.
pub fn receiver<F>(mut receive: F) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String>
where
	F: for<'a> FnMut(policy::Notice<'a, Ref>, Session) -> Result<Argument, String> + 'static,
{
	move |verb, args| {
		// One bounded stack view, no second decoded argument vector. Only dm
		// tolerates an excess suffix; every fixed-shape method still refuses it.
		let mut fields = [Value(&Argument::Void); policy::MAX_ARGUMENTS];
		for (field, arg) in fields.iter_mut().zip(args) {
			*field = Value(arg);
		}
		let notice = policy::read(verb, &fields[..args.len().min(policy::MAX_ARGUMENTS)]).map_err(|e| e.to_string())?;
		let session = glowcap::current_session()
			.map_err(|e| e.to_string())?
			.ok_or("a direct inbox needs a delivering session")?;
		receive(notice, session)
	}
}
pub struct Direct<D> {
	client: Client<D>,
	target: Option<Ref>,
	reply: Option<Ref>,
	registration: rooms_application::directory::registration::Id,
	owns_session: bool,
}
impl<D: Deadline> Direct<D> {
	/// Adopt an actual reply occurrence on its delivering connection.
	pub fn adopt(client: Client<D>, target: Ref, registration: rooms_application::directory::registration::Id) -> Self {
		Self {
			client,
			target: Some(target),
			reply: None,
			registration,
			owns_session: false,
		}
	}
	fn adopt_owned(
		client: Client<D>,
		target: Ref,
		registration: rooms_application::directory::registration::Id,
		owns_session: bool,
	) -> Self {
		Self {
			client,
			target: Some(target),
			reply: None,
			registration,
			owns_session,
		}
	}
	pub fn registration(&self) -> &rooms_application::directory::registration::Id {
		&self.registration
	}
	pub fn session(&self) -> &Session {
		&self.client.session
	}
	pub fn owns_session(&self) -> bool {
		self.owns_session
	}
	pub fn live(&self) -> bool {
		self.target.as_ref().is_some_and(|target| !target.released()) && self.session().is_open()
	}
	/// Reference identity is Host-scoped. Connection identity must agree before
	/// comparing arriving wrappers. This does not consult names or public keys.
	pub fn uses_route(&self, session: &Session, target: &Ref) -> bool {
		self.session().same_session(session)
			&& self
				.target
				.as_ref()
				.is_some_and(|held| held == target && !held.released())
	}
	pub fn same_route(&self, other: &Self) -> bool {
		other
			.target
			.as_ref()
			.is_some_and(|target| self.uses_route(other.session(), target))
	}
	pub fn with_receiver<F>(self, receive: F) -> Result<Self, Error>
	where
		F: for<'a> FnMut(policy::Notice<'a, Ref>, Session) -> Result<Argument, String> + 'static,
	{
		self.with_behavior(Box::new(receiver(receive)))
	}
	/// Host a complete reply protocol on this route's actual connection.
	pub fn with_behavior(mut self, behavior: glowcap::Behavior) -> Result<Self, Error> {
		self.target()?;
		self.reply = Some(self.client.session.spawn_owned(behavior)?);
		Ok(self)
	}
	fn target(&self) -> Result<&Ref, Error> {
		self.target.as_ref().ok_or_else(|| policy::Error::Ended.into())
	}
	pub fn file(&self, attachment: rooms_application::room::attachment::Attachment<Ref>) -> super::files::File<D>
	where
		D: Clone,
	{
		super::files::File::new(self.client.clone(), attachment)
	}
	pub async fn say(&self, text: &str) -> Result<Option<PostedLine<D>>, Error>
	where
		D: Clone,
	{
		self.say_with_previews(text, &Default::default()).await
	}
	pub async fn say_with_previews(
		&self,
		text: &str,
		previews: &rooms_application::open_graph::Selection,
	) -> Result<Option<PostedLine<D>>, Error>
	where
		D: Clone,
	{
		let pending = {
			let mut args = vec![text.into()];
			if let Some(reply) = &self.reply {
				args.push(reply.clone().into());
			}
			if !previews.is_empty() {
				args.push(rooms_application::open_graph::WIRE_TAG.into());
				args.push(previews.encode().into());
			}
			self.client.call(
				self.target()?,
				policy::DM,
				&args,
				"the peer did not answer the direct message",
			)
		};
		Ok(PostedLine::from_reply(self.client.clone(), pending.await?))
	}
	pub async fn establish_reply_route(&self) -> Result<(), Error> {
		let reply = self.reply.as_ref().ok_or(policy::Error::NoReply)?;
		self.client
			.call(
				self.target()?,
				policy::READY,
				&[reply.clone().into()],
				"the peer did not accept the reciprocal route",
			)
			.await?;
		Ok(())
	}
	pub fn typing(&self, on: bool) -> Result<(), Error> {
		self.client.session.tell(self.target()?, policy::TYPING, &[on.into()])?;
		Ok(())
	}
	pub async fn hand_room(&self, label: &str, room: &Ref) -> Result<(), Error> {
		self.client
			.call(
				self.target()?,
				policy::HAND_ROOM,
				&[label.into(), room.clone().into()],
				"the peer did not accept the handed room",
			)
			.await?;
		Ok(())
	}
	pub async fn offer_room(&self, label: &str, link: &str) -> Result<(), Error> {
		self.client
			.ask(
				self.target()?,
				policy::OFFER_ROOM,
				&[label, link],
				"the peer did not accept the room link",
			)
			.await?;
		Ok(())
	}
	pub async fn hand_archive(
		&self,
		directory: &str,
		kind: ShareKind,
		conversation: Option<&str>,
		archive: &Ref,
	) -> Result<(), Error> {
		self.archive(
			policy::HAND_ARCHIVE,
			directory,
			kind,
			conversation,
			archive.clone().into(),
		)
		.await
	}
	pub async fn offer_archive(
		&self,
		directory: &str,
		kind: ShareKind,
		conversation: Option<&str>,
		link: &str,
	) -> Result<(), Error> {
		self.archive(policy::OFFER_ARCHIVE, directory, kind, conversation, link.into())
			.await
	}
	async fn archive(
		&self,
		verb: &'static str,
		directory: &str,
		kind: ShareKind,
		conversation: Option<&str>,
		authority: Argument,
	) -> Result<(), Error> {
		let args = [
			directory.into(),
			kind.wire().into(),
			conversation.map(Argument::from).unwrap_or(Argument::Void),
			authority,
		];
		self.client
			.call(self.target()?, verb, &args, "the peer did not accept the archive offer")
			.await?;
		Ok(())
	}
	/// Release this line's occurrences. The Runtime owns the shared exporter
	/// connection, which may also carry sibling lines, files and delegated edits.
	pub fn close(&mut self) {
		self.reply = None;
		self.target = None;
	}
}
impl<D: Deadline + Tasks + Clone + 'static> directory::Directory<D> {
	pub async fn direct(
		&self,
		peer: &str,
		expected: Option<&rooms_application::directory::registration::Id>,
	) -> Result<Direct<D>, Error> {
		let introduced = self.introduce(peer, expected).await?;
		let (target, registration, session, owns_session) = introduced.into_parts();
		Ok(Direct::adopt_owned(
			Client::from_shared_session(session, self.client().deadline.clone()),
			target,
			registration,
			owns_session,
		))
	}
}

impl<D: Deadline + Tasks + Clone + 'static> Direct<D> {
	pub async fn send_files(
		&self,
		text: &str,
		owner: &super::sources::Sources<D>,
		files: Vec<super::sources::Source>,
	) -> Result<Option<PostedLine<D>>, Error> {
		self.send_files_with_previews(text, &Default::default(), owner, files)
			.await
	}
	pub async fn send_files_with_previews(
		&self,
		text: &str,
		previews: &rooms_application::open_graph::Selection,
		owner: &super::sources::Sources<D>,
		files: Vec<super::sources::Source>,
	) -> Result<Option<PostedLine<D>>, Error> {
		let mut leading = vec![text.into()];
		if let Some(reply) = &self.reply {
			leading.push(reply.clone().into());
		}
		let suffix = if previews.is_empty() {
			Vec::new()
		} else {
			vec![rooms_application::open_graph::WIRE_TAG.into(), previews.encode().into()]
		};
		let reply = owner
			.send_appended(&self.client, self.target()?, policy::DM, leading, files, suffix)
			.await?;
		Ok(PostedLine::from_reply(self.client.clone(), Reply(reply)))
	}
}
