use super::*;
use glowcap::{ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::files::FileDescription;

#[tokio::test]
async fn reissuing_retired_line_files_does_not_grow_reader_inventory() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
				.await
				.unwrap();
			let listener = tcp::listen("127.0.0.1", 0, Default::default()).await.unwrap();
			let locator = listener.locator().unwrap();
			let (session, peer) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), listener.accept());
			let session = session.unwrap();
			let peer = Rc::new(peer.unwrap().with_gc());
			let serving = {
				let peer = peer.clone();
				tokio::task::spawn_local(async move { peer.serve().await })
			};
			let cache = Capabilities::default();
			let mut store = FileStore::default();
			let room = store.room().unwrap();
			let member = store.member(&room).unwrap();
			let description = FileDescription::new("empty".into(), "application/octet-stream".into(), 0, 0, 0).unwrap();
			let minted = Cell::new(0);
			let mint = || {
				minted.set(minted.get() + 1);
				session.spawn_owned(|_, _| Ok(Argument::Void))
			};
			let mut expired = Vec::new();
			for _ in 0..16 {
				let upload = store.attach(&member, description.clone()).unwrap();
				let blob = upload.blob();
				let posted = store.post(&member).unwrap();
				cache.reader(&store, &blob, mint).unwrap();
				assert_eq!(cache.held.borrow().len(), 1, "one live file is the peak inventory");
				store.retire(&posted[0]).unwrap();
				expired.push(posted);
			}
			let current = store.attach(&member, description).unwrap().blob();
			let current_ref = cache.reader(&store, &current, mint).unwrap();
			assert_eq!(
				cache.held.borrow().len(),
				1,
				"the next insertion prunes every retired file"
			);
			let retirements = store.retirements();
			for posted in &expired {
				let blob = posted[0].blob();
				assert!(!store.contains(&blob));
				let first = cache.reader(&store, &blob, mint).unwrap();
				let again = cache.reader(&store, &blob, mint).unwrap();
				assert_ne!(first, again, "expired line files are reissued without a retained root");
				assert_eq!(cache.held.borrow().len(), 1, "expired misses cannot grow the inventory");
			}
			assert_eq!(
				store.retirements(),
				retirements,
				"no subsequent sweep masks stale insertion"
			);
			assert_eq!(minted.get(), 16 + 1 + 2 * expired.len());
			assert_eq!(cache.reader(&store, &current, mint).unwrap(), current_ref);
			assert_eq!(minted.get(), 49, "live reader identity is still shared");
			drop((cache, current_ref));
			session.close(PendingWork::Cancel).await.unwrap();
			peer.close(PendingWork::Cancel).await.unwrap();
			serving.await.unwrap().unwrap();
			runtime.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}
