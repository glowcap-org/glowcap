//! The native grant command owner runs over volatile tab documents in Wasm.
use glowcap::{Argument, CaptpVersion, Locator, Session};
use rooms_application::{
	documents::SessionDocument,
	grants::{
		Access,
		protocol::{self, GrantView},
	},
};
use rooms_browser::platform::Platform;
use rooms_glowcap::client::Client;
use rooms_runtime::{
	documents::{Document, VolatileDocument},
	grants::{
		DurableGrants, LoadError,
		commands::{GrantCommandEffects, GrantCommands, GrantNotice},
		publications::PublishedGrants,
	},
};
use std::{cell::Cell, rc::Rc};
const ID: &str = "00000000-0000-4000-8000-000000000001";

struct Notices(Rc<Cell<usize>>);
impl GrantCommandEffects for Notices {
	fn local_reply_failed(&mut self, error: String) {
		panic!("unexpected abandoned grant failure: {error}");
	}
	fn reply_failed(&mut self, error: glowcap::Error) {
		panic!("grant reply: {error}");
	}
	async fn changed<D: Document>(
		&mut self,
		notice: GrantNotice<'_>,
		grants: &PublishedGrants<D>,
	) -> Result<(), String> {
		match notice {
			GrantNotice::Committed { .. } => {
				grants.grants().map_err(|e| e.to_string())?;
			}
			GrantNotice::Unavailable => assert!(grants.grants().is_err()),
			GrantNotice::Routed => assert!(grants.grants().is_ok()),
		}
		self.0.set(self.0.get() + 1);
		Ok(())
	}
}
fn view(value: Argument) -> GrantView {
	GrantView::decode(value.as_str().unwrap()).unwrap()
}
fn issue() -> [Argument; 4] {
	[ID.into(), "interact".into(), "browser".into(), false.into()]
}

pub async fn exercise(client: &Client<Platform>, accepted: &Session, locator: &Locator) {
	let wrong = VolatileDocument::new(SessionDocument::Checkpoint);
	let mut wrong = DurableGrants::new(wrong);
	assert!(matches!(wrong.load().await, Err(LoadError::Role)));
	assert!(wrong.ledger().is_err());

	let grants = DurableGrants::new(VolatileDocument::new(SessionDocument::Grants));
	let (commands, worker) = GrantCommands::open(grants, accepted.host(), [82; 16], locator.clone(), || {
		Box::new(|_, grant, verb, _| match verb {
			"access" => Ok(format!("{:?}/{}", grant.access(), grant.history()).into()),
			"write" if grant.access() == Access::Interact || grant.access() == Access::Admin => Ok("written".into()),
			_ => Err("grant refuses operation".into()),
		})
	})
	.await
	.unwrap();
	assert!(worker.views().unwrap().is_empty());
	let notices = Rc::new(Cell::new(0));
	let running = tokio::task::spawn_local(worker.run(Notices(notices.clone())));
	let root_name = accepted
		.host()
		.publish_durable_with_entropy([82; 16], || commands.admin_behavior())
		.unwrap();
	let session = client.session();
	let root = session.fetch(&root_name).await.unwrap();
	let issued = view(session.send(&root, protocol::ISSUE, &issue()).await.unwrap());
	assert_eq!(notices.get(), 1, "notification precedes reply");
	let parsed = glowcap::parse_sturdyref(&issued.sturdyref, CaptpVersion::V1_0).unwrap();
	let name = core::str::from_utf8(&parsed.swissnum).unwrap();
	let held = session.fetch(name).await.unwrap();
	assert_eq!(
		session.send(&held, "write", &[]).await.unwrap().as_str(),
		Some("written")
	);
	assert!(session.send(&held, protocol::ISSUE, &issue()).await.is_err());
	let policy = [ID.into(), "observe".into(), true.into(), Argument::Void, Argument::Void];
	let narrowed = view(session.send(&root, protocol::SET_POLICY, &policy).await.unwrap());
	assert_eq!(narrowed.sturdyref, issued.sturdyref);
	assert_eq!(notices.get(), 2);
	assert!(session.send(&held, "write", &[]).await.is_err());
	assert_eq!(
		session.send(&held, "access", &[]).await.unwrap().as_str(),
		Some("Observe/true")
	);
	session.send(&root, protocol::REVOKE, &[ID.into()]).await.unwrap();
	assert_eq!(notices.get(), 3);
	assert!(session.send(&held, "access", &[]).await.is_err());
	assert!(session.fetch(name).await.is_err());
	commands.close().await.unwrap();
	commands.close().await.unwrap();
	running.await.unwrap().unwrap();
	assert_eq!(notices.get(), 4);
	assert!(session.send(&root, protocol::ISSUE, &issue()).await.is_err());
	accepted.host().remove_durable(&root_name).unwrap();
	// A new tab owner cannot restore a prior tab's grants from workspace storage.
	let mut fresh = DurableGrants::new(VolatileDocument::new(SessionDocument::Grants));
	fresh.load().await.unwrap();
	assert_eq!(fresh.ledger().unwrap().active_count().unwrap(), 0);
}
