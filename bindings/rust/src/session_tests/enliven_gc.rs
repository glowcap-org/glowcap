//! Each cache-issued enliven result owns one independently releasable occurrence.
use super::support::*;
#[tokio::test]
async fn gc_releases_fresh_and_cached_enliven_occurrences_independently() {
	LocalSet::new()
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let locator = tcp::locator("127.0.0.1", server.port().unwrap());
			let (ready, started) = oneshot::channel();
			let serving = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session.publish("authority", |_, _| Ok("alive".into())).unwrap();
				ready.send(()).unwrap();
				session.serve().await.unwrap();
			});
			let session = connect(&locator, ConnectOptions::default()).await.unwrap();
			started.await.unwrap();
			let link = crate::format_sturdyref(&locator, b"authority", crate::CaptpVersion::V1_0).unwrap();
			let first = session.enliven(&link).await.unwrap();
			let second = session.enliven(&link).await.unwrap();
			assert_eq!(first, second);
			// Retain only the old opaque id as a test probe, not another owned Ref.
			let stale = Ref::bare_id(first.id());
			drop(first);
			session.shared.drain_gc().unwrap();
			assert_eq!(
				session.send(&second, "probe", &[]).await.unwrap().as_str(),
				Some("alive")
			);
			drop(second);
			session.shared.drain_gc().unwrap();
			assert!(
				session.send(&stale, "probe", &[]).await.is_err(),
				"last enliven occurrence leaked its application retain"
			);
			let fresh = session.enliven(&link).await.unwrap();
			assert_ne!(fresh, stale);
			assert_eq!(
				session.send(&fresh, "probe", &[]).await.unwrap().as_str(),
				Some("alive")
			);
			drop(fresh);
			session.shared.drain_gc().unwrap();
			session.close(crate::PendingWork::Cancel).await.unwrap();
			serving.await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn owned_actor_drop_retires_its_local_root_without_gc_opt_in() {
	struct Probe(Rc<Cell<u32>>);
	impl Drop for Probe {
		fn drop(&mut self) {
			self.0.set(self.0.get() + 1);
		}
	}
	LocalSet::new()
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let locator = tcp::locator("127.0.0.1", server.port().unwrap());
			let serving = tokio::task::spawn_local(async move {
				server.accept().await.unwrap().serve().await.unwrap();
			});
			let session = connect(&locator, ConnectOptions::default()).await.unwrap();
			let fence = session.spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
			let drops = Rc::new(Cell::new(0));
			let probe = Probe(drops.clone());
			let first = session
				.spawn_owned(move |_, _| {
					let _keep = &probe;
					Ok("alive".into())
				})
				.unwrap();
			let second = first.clone();
			let stale = Ref::bare_id(first.id());
			drop(first);
			session.shared.drain_gc().unwrap();
			assert_eq!(drops.get(), 0);
			assert_eq!(
				session.send(&second, "probe", &[]).await.unwrap().as_str(),
				Some("alive")
			);
			drop(second);
			session.shared.drain_gc().unwrap();
			assert!(session.send(&stale, "probe", &[]).await.is_err());
			session.send(&fence, "fence", &[]).await.unwrap();
			assert_eq!(drops.get(), 1);
			let probe = Probe(drops.clone());
			let explicit = session
				.spawn_owned(move |_, _| {
					let _keep = &probe;
					Ok(Argument::Void)
				})
				.unwrap();
			session.release(explicit).unwrap();
			session.shared.drain_gc().unwrap();
			assert!(session.send(&stale, "probe", &[]).await.is_err());
			session.send(&fence, "fence", &[]).await.unwrap();
			assert_eq!(drops.get(), 2);
			session.close(crate::PendingWork::Cancel).await.unwrap();
			serving.await.unwrap();
		})
		.await;
}
