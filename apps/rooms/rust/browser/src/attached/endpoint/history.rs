use super::*;
use rooms_application::archive::{self, ConversationKind, Filter, ShareKind};
use rooms_glowcap::client::{
	archive::ShareView,
	session::{HistoryView, SharedHistory},
};
impl Endpoint {
	pub async fn history(&self, kind: ConversationKind, directory: &str, conversation: &str) -> Result<HistoryView> {
		match self {
			Self::Remote(s) => s.history_view(kind, directory, conversation).await.map_err(error),
			Self::Local(s, _) => {
				let filter = Filter {
					conversation_kind: Some(kind),
					directory: Some(directory.into()),
					conversation: Some(conversation.into()),
					..Default::default()
				};
				filter.validate().map_err(error)?;
				let view = s.history_view(filter).await.map_err(error)?;
				Ok(HistoryView {
					records: view
						.records
						.into_iter()
						.map(|row| std::sync::Arc::unwrap_or_clone(row.record))
						.collect(),
					local: view.local,
					peer: view.peer,
				})
			}
		}
	}
	pub async fn share_archive(&self, kind: ShareKind, conversation: &str, peer: Option<&str>) -> Result<()> {
		match self {
			Self::Remote(s) => s.share_archive(kind, conversation, peer).await.map_err(error),
			Self::Local(s, _) => s
				.share_archive(kind, conversation, peer, false)
				.map_err(error)?
				.wait()
				.await
				.map_err(error),
		}
	}
	pub async fn offer_durable_archive(&self, kind: ShareKind, conversation: &str, peer: Option<&str>) -> Result<()> {
		match self {
			Self::Remote(s) => s.offer_durable_archive(kind, conversation, peer).await.map_err(error),
			Self::Local(s, _) => s
				.share_archive(kind, conversation, peer, true)
				.map_err(error)?
				.wait()
				.await
				.map_err(error),
		}
	}
	pub async fn drop_archive_share(&self, id: &str) -> Result<()> {
		match self {
			Self::Remote(s) => s.drop_archive_share(id).await.map_err(error),
			Self::Local(s, _) => s.drop_archive_share(id).map_err(error),
		}
	}
	pub async fn revoke_archive_share(&self, id: &str) -> Result<bool> {
		match self {
			Self::Remote(s) => s.revoke_archive_share(id).await.map_err(error),
			Self::Local(s, _) => s
				.revoke_archive_share(id.into())
				.map_err(error)?
				.wait()
				.await
				.map_err(error),
		}
	}
	pub async fn issued_archive_shares(&self) -> Result<Vec<ShareView>> {
		match self {
			Self::Remote(s) => s.issued_archive_shares().await.map_err(error),
			Self::Local(s, _) => s.issued_archive_shares().map_err(error)?.wait().await.map_err(error),
		}
	}
	pub async fn read_archive_share(&self, id: &str) -> Result<SharedHistory> {
		let Self::Local(s, _) = self else {
			let Self::Remote(s) = self else { unreachable!() };
			return s.read_archive_share(id).await.map_err(error);
		};
		let mut after = 0;
		let mut view = None;
		let mut records = Vec::new();
		loop {
			let (current, page) = s
				.read_archive_share(id, after)
				.map_err(error)?
				.wait()
				.await
				.map_err(error)?;
			if view.as_ref().is_some_and(|previous| previous != &current)
				|| page.next < after
				|| (page.more && (page.next == after || page.records.is_empty()))
				|| records.len() + page.records.len() > archive::MAX_RECORDS
			{
				return Err(
					"Rooms archive-share scan changed identity or exceeded its progress or record bounds".into(),
				);
			}
			records.extend(page.records.into_iter().map(|entry| (*entry.record).clone()));
			if !page.more {
				return Ok(SharedHistory { view: current, records });
			}
			view = Some(current);
			after = page.next;
		}
	}
}
