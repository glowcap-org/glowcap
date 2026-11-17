//! A restart with the effect unresolved: the worker, its live custody and the
//! session's connections are gone, and only the stored receipt remains.
use super::{
	super::{environment, *},
	rig::Rig,
};

/// The session after a physical reopening, still facing the same exporters.
pub(super) struct Cold {
	pub(super) host: Host,
	pub(super) owner: managed::Session<Platform>,
	pub(super) root: Ref,
	attachment: loam::Attachment,
	store: loam::Store,
	database: Database,
	exporters: [Host; 2],
}
impl Rig {
	/// Stop the session where it is and reopen its store without live custody.
	pub(super) async fn go_cold(self) -> Cold {
		let marker = self.attachment.live_marker().unwrap().unwrap();
		let Self {
			host,
			owner,
			mut attachment,
			sessions,
			exporter,
			other,
			database,
			mut store,
			schemas,
			limits,
			resource,
			..
		} = self;
		// The unresolved effect is retained, so closing reports it.
		for session in sessions {
			session.close(PendingWork::Cancel).await.unwrap();
		}
		// tolerant: closing reports an effect it still retains. The scenario reads
		// that same fact from the reopened receipt, which is the evidence it asserts.
		let _retained = owner.close().await;
		attachment.close().await.unwrap();
		host.close(PendingWork::Cancel).await.unwrap();
		drop(owner);
		environment::close(&mut store).await;
		drop(store);
		let store = database.open(false, &schemas, limits).await;
		let host = Host::from_seed([141; 32]).unwrap();
		let owner = managed::Session::new(
			host.clone(),
			Platform::default(),
			std::num::NonZeroUsize::new(1 << 17).unwrap(),
		);
		let attachment = store.attach(&host, vec![owner.registration()]).unwrap();
		environment::start_live(&attachment, Some(marker), 64).await;
		let (root, control) = environment::restore(&attachment, loam::Resource::decode(resource.encode())).await;
		owner.bind(root.clone(), control).unwrap();
		Cold {
			host,
			owner,
			root,
			attachment,
			store,
			database,
			exporters: [exporter, other],
		}
	}
}
impl Cold {
	pub(super) async fn close(mut self) {
		self.owner.close().await.unwrap();
		self.attachment.close().await.unwrap();
		self.host.close(PendingWork::Cancel).await.unwrap();
		drop(self.owner);
		environment::close(&mut self.store).await;
		drop(self.store);
		for exporter in self.exporters {
			exporter.close(PendingWork::Cancel).await.unwrap();
		}
		self.database.remove();
	}
}
