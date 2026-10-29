//! Acknowledged callbacks keep exact recovery input across refusal and delayed completion.
use super::super::{Session, inbox};
use super::*;
use rooms_application::{content::session::custody, fields::Text};
use std::{
	cell::{Cell, RefCell},
	num::{NonZeroU64, NonZeroUsize},
};

#[derive(Clone)]
struct Platform;
struct Task(tokio::task::JoinHandle<()>);
impl Drop for Task {
	fn drop(&mut self) {
		self.0.abort();
	}
}
impl Tasks for Platform {
	type Task = Task;
	fn spawn(&self, work: impl std::future::Future<Output = ()> + 'static) -> Task {
		Task(tokio::task::spawn_local(work))
	}
}
impl Deadline for Platform {
	fn monotonic_millis(&self) -> u64 {
		0
	}
	async fn within<T>(&self, ms: u64, work: impl std::future::Future<Output = T>) -> Option<T> {
		tokio::time::timeout(std::time::Duration::from_millis(ms.min(20)), work)
			.await
			.ok()
	}
}
fn key<K>() -> custody::FieldKey<K> {
	custody::FieldKey::new(NonZeroU64::new(1).unwrap(), NonZeroU64::new(1).unwrap())
}
async fn until(mut ready: impl FnMut() -> bool) {
	tokio::time::timeout(std::time::Duration::from_secs(2), async {
		while !ready() {
			tokio::task::yield_now().await;
		}
	})
	.await
	.unwrap();
}
#[tokio::test]
async fn acknowledged_route_retains_refusal_and_original_completion_until_recovery() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = glowcap::Host::from_seed([219; 32]).unwrap();
			let refuse = Rc::new(Cell::new(true));
			let calls = Rc::new(RefCell::new(Vec::new()));
			let answer = Rc::new(RefCell::new(None));
			let source = host
				.spawn({
					let (host, refuse, calls, answer) = (host.clone(), refuse.clone(), calls.clone(), answer.clone());
					move |verb, args| {
						if matches!(verb, Some("check-inbox" | "record-inbox")) {
							return Ok(Argument::Boolean(false));
						}
						assert_eq!(verb, Some("adopt-direct-route"));
						calls.borrow_mut().push(args.to_vec());
						if refuse.get() {
							return Err("storage unavailable".into());
						}
						*answer.borrow_mut() = Some(host.defer_turn().unwrap());
						Ok(Argument::Void)
					}
				})
				.unwrap();
			let owner = Session::new(host.clone(), Platform, NonZeroUsize::new(8192).unwrap());
			owner.state.writer.bind(source.clone(), source.clone()).unwrap();
			owner.on_trouble(|_, _| {}).unwrap();
			let selected = InboxSelection::Direct {
				id: Text::new("conversation".into()).unwrap(),
				directory: Text::new("directory".into()).unwrap(),
				peer: Text::new("peer".into()).unwrap(),
				access: None,
				introduction: None,
				source: key(),
				inbox: key(),
			};
			let mut callback = inbox::open(
				&host,
				Platform,
				rooms_glowcap::client::workspace::Workspace::local(host.clone(), Platform, source.clone()),
				selected,
				owner.state.inboxes.clone(),
				{
					let state = Rc::downgrade(&owner.state);
					move |verb, args, _, origin| {
						assert_eq!(verb, rooms_application::direct::READY);
						let Argument::Reference(reference) = &args[0] else {
							panic!("actual route capability");
						};
						route(&state, origin, reference).map_err(|e| e.to_string())?;
						Ok(Argument::Void)
					}
				},
			)
			.unwrap();
			let peer = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
			host.send(callback.reference(), rooms_application::direct::READY, &[peer.into()])
				.await
				.unwrap();
			until(|| failure(&owner.state.introductions.borrow()).is_some()).await;
			assert_eq!(calls.borrow().len(), 1);
			assert!(
				owner.close().await.is_err(),
				"failed admission remains a shutdown barrier"
			);
			refuse.set(false);
			owner.resume_pending().unwrap();
			until(|| answer.borrow().is_some()).await;
			assert_eq!(
				calls.borrow()[0],
				calls.borrow()[1],
				"retry retains original source selection, callback and route"
			);
			owner.resume_pending().unwrap();
			assert!(
				owner.close().await.is_err(),
				"a missed completion retains the original receiver"
			);
			assert_eq!(calls.borrow().len(), 2, "pending admission cannot be redispatched");
			answer.borrow_mut().take().unwrap().fulfill(&Argument::Void).unwrap();
			until(|| owner.state.introductions.borrow().is_empty()).await;
			callback.close().await.unwrap();
			owner.close().await.unwrap();
			drop((callback, source, owner, calls, answer));
			host.close(glowcap::PendingWork::Cancel).await.unwrap();
		})
		.await;
}
