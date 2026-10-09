//! Actual exporter sessions remain open until their final supervised user retires.
use super::*;
use crate::session::managed::supervision::retirement::Owner;
use glowcap::{Host, PendingWork, Runtime, RuntimeConfig, Session, tcp};

async fn connection() -> (Session, tokio::task::JoinHandle<()>) {
	let host = Host::from_seed([126; 32]).unwrap();
	let server = tcp::listen(
		"127.0.0.1",
		0,
		tcp::ListenOptions {
			identity: glowcap::ListenerIdentity::Host(host),
			..Default::default()
		},
	)
	.await
	.unwrap();
	let locator = tcp::locator("127.0.0.1", server.port().unwrap());
	let peer = tokio::task::spawn_local(async move {
		let accepted = server.accept().await.unwrap();
		accepted.serve().await.unwrap();
	});
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let session = runtime.connect(&locator, Default::default()).await.unwrap();
	(session, peer)
}

#[tokio::test]
async fn closing_one_direct_preserves_siblings_and_the_last_closes_the_exporter() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let (session, peer) = connection().await;
			let budget = Rc::new(Budget::default());
			let first = Rc::new(Owner::new(session.host()));
			let second = Rc::new(Owner::new(session.host()));
			let mut views = Vec::new();
			for (id, owner) in [("first", first.clone()), ("second", second.clone())] {
				owner.observe(Some(session.borrowed())).unwrap();
				let view = spawn(&Platform, &budget, id.into(), Some(owner), |mut signals| async move {
					signals.ready.send_replace(Some(Ok(())));
					signals.stopping.changed().await.unwrap();
					Ok(())
				});
				view.ready().await.unwrap();
				views.push(view);
			}
			budget.close_direct_connection(&first).await.unwrap();
			assert!(session.is_open(), "a sibling still owns this exact exporter");
			budget.close_direct_connection(&second).await.unwrap();
			assert!(!session.is_open(), "the final direct releases its connection");
			budget.close_all().await.unwrap();
			drop(views);
			peer.await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn late_exporter_installation_wakes_the_existing_end_observer() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let (session, peer) = connection().await;
			let owner = Rc::new(Owner::new(session.host()));
			owner.absent();
			let observing = tokio::task::spawn_local({
				let owner = owner.clone();
				async move { owner.ended().await }
			});
			tokio::task::yield_now().await;
			assert!(!observing.is_finished());
			owner.observe(Some(session.borrowed())).unwrap();
			owner.observe(Some(session.borrowed())).unwrap();
			owner.absent();
			assert!(
				owner.connection().unwrap().same_connection(&session),
				"an acknowledgment cannot erase lifetime custody"
			);
			session.close(PendingWork::Cancel).await.unwrap();
			tokio::time::timeout(std::time::Duration::from_secs(2), observing)
				.await
				.unwrap()
				.unwrap()
				.unwrap();
			assert!(owner.connection_lost());
			owner.close().await.unwrap();
			peer.await.unwrap();
		})
		.await;
}
