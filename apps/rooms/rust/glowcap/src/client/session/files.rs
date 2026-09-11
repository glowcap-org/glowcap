use super::*;
use crate::client::{
	files::File,
	sources::{Source, Sources},
	Tasks,
};
use rooms_application::{
	archive::{self, Body, ConversationKind, Filter, Record},
	room::attachment::Attachment,
};

pub struct FileMessage<'a> {
	pub operation: &'a str,
	pub base: u64,
	pub conversation: &'a str,
	pub caption: &'a str,
}
pub struct Refile<'a> {
	pub message: FileMessage<'a>,
	pub line: u64,
	pub keep: &'a [u32],
}
pub struct HistoryView {
	pub records: Vec<Record>,
	pub local: bool,
	pub peer: bool,
}

impl<D: Deadline + Clone> Session<D> {
	pub fn attachment(&self, attachment: Attachment<Ref>) -> File<D> {
		File::received(self.client.clone(), attachment)
	}
	pub async fn history(
		&self,
		kind: ConversationKind,
		directory: &str,
		conversation: &str,
	) -> Result<Vec<Record>, Error> {
		let filter = Filter {
			conversation_kind: Some(kind),
			directory: Some(directory.into()),
			conversation: Some(conversation.into()),
			..Default::default()
		};
		filter.validate().map_err(crate::client::Error::from)?;
		let kind = match kind {
			ConversationKind::Room => "room",
			ConversationKind::Direct => "direct",
		};
		let reply = self
			.call(
				verbs::READ_HISTORY,
				&[kind.into(), directory.into(), conversation.into()],
			)
			.await?;
		let rows = reply
			.as_list()
			.filter(|rows| rows.len() <= archive::MAX_RECORDS)
			.ok_or(Error::Reply("invalid Rooms history record list"))?;
		rows.iter()
			.map(|row| {
				let record = archive::protocol::record(&Value(row)).map_err(crate::client::Error::from)?;
				if !filter.matches(&record) {
					return Err(Error::Reply("Rooms history returned another conversation"));
				}
				Ok(record)
			})
			.collect()
	}
	pub async fn history_view(
		&self,
		kind: ConversationKind,
		directory: &str,
		conversation: &str,
	) -> Result<HistoryView, Error> {
		let filter = Filter {
			conversation_kind: Some(kind),
			directory: Some(directory.into()),
			conversation: Some(conversation.into()),
			..Default::default()
		};
		filter.validate().map_err(crate::client::Error::from)?;
		let kind = match kind {
			ConversationKind::Room => "room",
			ConversationKind::Direct => "direct",
		};
		let reply = self
			.call(
				verbs::READ_HISTORY_VIEW,
				&[kind.into(), directory.into(), conversation.into()],
			)
			.await?;
		let [local, peer, rows] = reply
			.as_list()
			.filter(|values| values.len() == 3)
			.ok_or(Error::Reply("invalid Rooms combined history view"))?
		else {
			unreachable!("checked history view length")
		};
		let rows = rows
			.as_list()
			.filter(|rows| rows.len() <= archive::MAX_RECORDS)
			.ok_or(Error::Reply("invalid Rooms combined history record list"))?;
		let records = rows
			.iter()
			.map(|row| {
				let record = archive::protocol::record(&Value(row)).map_err(crate::client::Error::from)?;
				if !filter.matches(&record) {
					return Err(Error::Reply("Rooms combined history returned another conversation"));
				}
				Ok(record)
			})
			.collect::<Result<Vec<_>, _>>()?;
		Ok(HistoryView {
			records,
			local: local
				.as_bool()
				.ok_or(Error::Reply("invalid Rooms combined history local custody"))?,
			peer: peer
				.as_bool()
				.ok_or(Error::Reply("invalid Rooms combined history peer custody"))?,
		})
	}
	pub async fn archived_attachment(&self, record: &Record, index: usize) -> Result<File<D>, Error> {
		let Body::Line { attachments, .. } = record.body() else {
			return Err(Error::Reply("archive record is not a line"));
		};
		let metadata = attachments
			.get(index)
			.filter(|a| a.blob().is_some())
			.ok_or(Error::Reply("archive record has no retained file at this index"))?;
		let description = metadata.live_description().map_err(crate::client::Error::from)?;
		let reply = self
			.call(
				verbs::ARCHIVED_ATTACHMENT,
				&[crate::archive::record_row(record), Argument::Integer(index as i64)],
			)
			.await?;
		let Argument::Reference(blob) = reply else {
			return Err(Error::Reply("Rooms session returned no archived file capability"));
		};
		Ok(self.attachment(Attachment { description, blob }))
	}
}
impl<D: Deadline + Tasks + Clone + 'static> Session<D> {
	/// The session service consumes the supplied bytes before acknowledging.
	/// The application supplies its one source pool; this call creates no pool.
	pub async fn send_files(
		&self,
		pool: &Sources<D>,
		message: FileMessage<'_>,
		sources: Vec<Source>,
	) -> Result<u64, Error> {
		let mut args = transaction(message.operation, message.base)?;
		args.extend([message.conversation.into(), message.caption.into()]);
		let reply = pool
			.send_scoped(&self.client, &self.reference, verbs::SEND_FILES, args, sources)
			.await?;
		revision(&reply)
	}
	pub async fn refile(&self, pool: &Sources<D>, refile: Refile<'_>, sources: Vec<Source>) -> Result<u64, Error> {
		if refile.keep.len() > rooms_application::room::line::MAX_MESSAGE_FILES
			|| rooms_application::room::message::LineId::new(refile.line).is_none()
		{
			return Err(Error::Reply("invalid Rooms refile selection"));
		}
		let mut args = transaction(refile.message.operation, refile.message.base)?;
		args.extend([
			refile.message.conversation.into(),
			Argument::Integer(refile.line as i64),
			refile.message.caption.into(),
		]);
		args.extend(refile.keep.iter().map(|index| Argument::Integer((*index).into())));
		let reply = pool
			.send_scoped(&self.client, &self.reference, verbs::REFILE_LINE, args, sources)
			.await?;
		revision(&reply)
	}
}
