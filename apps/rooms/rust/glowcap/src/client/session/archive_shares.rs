use super::*;
use rooms_application::{
	archive::{self, Filter, Record, ShareKind},
	session::snapshot::views::ArchiveShare,
};

pub struct SharedHistory {
	pub view: ArchiveShare,
	pub records: Vec<Record>,
}
impl<D: Deadline> Session<D> {
	pub async fn share_archive(&self, kind: ShareKind, conversation: &str, peer: Option<&str>) -> Result<(), Error> {
		self.offer_archive(verbs::SHARE_ARCHIVE, kind, conversation, peer).await
	}
	pub async fn offer_durable_archive(
		&self,
		kind: ShareKind,
		conversation: &str,
		peer: Option<&str>,
	) -> Result<(), Error> {
		self.offer_archive(verbs::OFFER_DURABLE_ARCHIVE, kind, conversation, peer)
			.await
	}
	async fn offer_archive(
		&self,
		verb: &'static str,
		kind: ShareKind,
		conversation: &str,
		peer: Option<&str>,
	) -> Result<(), Error> {
		let mut args = vec![kind.wire().into(), conversation.into()];
		if let Some(peer) = peer {
			args.push(peer.into());
		}
		self.call(verb, &args).await?;
		Ok(())
	}
	pub async fn drop_archive_share(&self, id: &str) -> Result<(), Error> {
		self.call(verbs::DROP_ARCHIVE_SHARE, &[id.into()]).await?;
		Ok(())
	}
	pub async fn issued_archive_shares(&self) -> Result<Vec<crate::client::archive::ShareView>, Error> {
		let reply = self.call(verbs::LIST_ARCHIVE_SHARES, &[]).await?;
		Ok(crate::client::archive::read_share_views(reply)?)
	}
	pub async fn revoke_archive_share(&self, id: &str) -> Result<bool, Error> {
		self.call(verbs::REVOKE_ARCHIVE_SHARE, &[id.into()])
			.await?
			.as_bool()
			.ok_or(Error::Reply(
				"Rooms session returned no archive-share revocation result",
			))
	}
	pub async fn read_archive_share(&self, id: &str) -> Result<SharedHistory, Error> {
		let mut after = 0;
		let mut view = None;
		let mut records = Vec::new();
		loop {
			let reply = self
				.call(verbs::READ_ARCHIVE_SHARE, &[id.into(), Argument::Integer(after as i64)])
				.await?;
			let Some([metadata, next, more, rows]) = reply.as_list() else {
				return Err(Error::Reply("invalid Rooms archive-share page"));
			};
			let metadata = metadata
				.as_str()
				.ok_or(Error::Reply("invalid Rooms archive-share view"))?;
			let current = ArchiveShare::decode(metadata)?;
			if current.id.text().as_str() != Some(id) || view.as_ref().is_some_and(|old| *old != current) {
				return Err(Error::Reply(
					"Rooms session changed archive-share identity between pages",
				));
			}
			let filter = Filter::shared(
				current.kind,
				current.directory.text().clone(),
				current.scope_conversation.as_ref().cloned(),
			)
			.map_err(crate::client::Error::from)?;
			let next = revision(next)?;
			let more = more
				.as_bool()
				.ok_or(Error::Reply("invalid Rooms archive-share continuation"))?;
			let rows = rows
				.as_list()
				.filter(|rows| rows.len() <= archive::MAX_READ)
				.ok_or(Error::Reply("invalid Rooms archive-share record list"))?;
			if next < after
				|| (more && (next == after || rows.is_empty()))
				|| records.len() + rows.len() > archive::MAX_RECORDS
			{
				return Err(Error::Reply(
					"Rooms archive-share scan exceeds its progress or record bounds",
				));
			}
			for row in rows {
				let record = archive::protocol::record(&Value(row)).map_err(crate::client::Error::from)?;
				if !filter.matches(&record) {
					return Err(Error::Reply("Rooms archive share returned a record outside its scope"));
				}
				records.push(record);
			}
			if !more {
				return Ok(SharedHistory { view: current, records });
			}
			view = Some(current);
			after = next;
		}
	}
}
