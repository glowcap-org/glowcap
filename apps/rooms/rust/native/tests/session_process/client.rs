//! The same attached client the browser uses crosses the executable's listener.
use glowcap::{iroh, tcp, CaptpVersion, ConnectOptions, PendingWork, Runtime, RuntimeConfig};
use rooms_application::{
	grants::{Access, Rights},
	session::snapshot::Snapshot,
};
use rooms_glowcap::client::{
	session::{Event, Observer, Session},
	Client,
};
use rooms_native::client::Deadline;
use std::{cell::Cell, rc::Rc, time::Duration};

struct Views(Rc<Cell<u64>>, Rc<Cell<bool>>);
impl Drop for Views {
	fn drop(&mut self) {
		self.1.set(true);
	}
}
impl Observer for Views {
	fn changed(&mut self, snapshot: Snapshot) -> Result<(), String> {
		self.0.set(snapshot.revision.get());
		Ok(())
	}
	fn event(&mut self, _: Event<glowcap::Ref>) -> Result<(), String> {
		Ok(())
	}
	fn history_changed(&mut self, _: rooms_application::archive::change::Change) -> Result<(), String> {
		Ok(())
	}
	fn operations_changed(&mut self, _: &str) -> Result<(), String> {
		Ok(())
	}
}
pub fn exercise(link: &str) {
	tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap()
		.block_on(tokio::task::LocalSet::new().run_until(async {
			tokio::time::timeout(Duration::from_secs(8), attached(link))
				.await
				.expect("native attached-session deadline");
		}));
}
async fn attached(link: &str) {
	let parsed = glowcap::parse_sturdyref(link, CaptpVersion::V1_0).unwrap();
	let runtime = Runtime::open(RuntimeConfig::providers([
		tcp::provider(Default::default()),
		iroh::provider(iroh::Config::new(iroh::Reachability::Direct)),
	]))
	.await
	.unwrap();
	let connection = runtime
		.connect(&parsed.locator, ConnectOptions::default())
		.await
		.unwrap();
	let session = Session::enliven(Client::new(connection, Deadline), link).await.unwrap();
	let changed = Rc::new(Cell::new(0));
	let retired = Rc::new(Cell::new(false));
	let (initial, watch) = session.watch(Views(changed.clone(), retired.clone())).await.unwrap();
	assert_eq!(initial.access, Access::Admin);
	// The same operation is retried after process restart. Its durable receipt
	// must answer revision one without mutating the restored document again.
	assert_eq!(
		session
			.command("executable-attach", 0, "setStanding", &["present".into()])
			.await
			.unwrap(),
		1
	);
	assert_eq!(session.snapshot().await.unwrap().revision.get(), 1);
	assert!(
		initial.revision.get() == 1 || changed.get() == 1,
		"watch precedes first commit reply"
	);
	let facet = session.facet(Rights::Observe).await.unwrap();
	assert_eq!(facet.session.snapshot().await.unwrap().access, Access::Observe);
	assert!(facet
		.session
		.command("observer-write", 1, "setStanding", &["present".into()])
		.await
		.is_err());
	facet.revoke().await.unwrap();
	assert!(facet.session.snapshot().await.is_err());
	drop(watch);
	assert!(retired.get());
	drop((facet, session));
	runtime.close(PendingWork::Cancel).await.unwrap();
}
