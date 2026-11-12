//! Shutdown must observe socket retirement, including failed setup.
use super::{Input, Publisher, Socket, Transport};
use crate::Error;
use rooms_glowcap::client::Deadline;
use std::{cell::RefCell, future::Future, rc::Rc};
use tokio::sync::watch;

#[test]
fn publisher_preserves_exact_exporter_route_and_rejects_embedded_credentials() {
	for path in ["/publish", "/nested/publish"] {
		let route = format!("wss://localhost:8443{path}");
		assert_eq!(
			super::publish_target(&route).unwrap(),
			route,
			"the capability never joins the route"
		);
	}
	for endpoint in [
		"wss://user:secret@localhost/publish",
		"ws://localhost/publish?cap=old",
		"ws://localhost/#fragment",
		"https://localhost/publish",
	] {
		assert!(super::publish_target(endpoint).is_err());
	}
}

#[derive(Clone)]
struct Probe {
	setup: Result<(), Error>,
	opened: watch::Sender<bool>,
	closing: watch::Sender<bool>,
	released: watch::Receiver<Option<Result<(), Error>>>,
	/// Each route connected, then each message sent, in order.
	said: Rc<RefCell<Vec<String>>>,
}
impl Deadline for Probe {
	fn monotonic_millis(&self) -> u64 {
		0
	}
	async fn within<T>(&self, _: u64, work: impl Future<Output = T>) -> Option<T> {
		Some(work.await)
	}
}
impl Transport for Probe {
	type Socket = Self;
	async fn connect(&self, target: &str) -> Result<Self, Error> {
		self.said.borrow_mut().push(target.into());
		self.opened.send_replace(true);
		Ok(self.clone())
	}
	async fn sleep(&self, _: u64) {
		std::future::pending().await
	}
}
impl Socket for Probe {
	async fn ready(&mut self) -> Result<(), Error> {
		self.setup.clone()
	}
	async fn next(&mut self) -> Result<Input, Error> {
		std::future::pending().await
	}
	async fn send(&mut self, text: String) -> Result<(), Error> {
		self.said.borrow_mut().push(text);
		Ok(())
	}
	async fn close(&mut self) -> Result<(), Error> {
		self.closing.send_replace(true);
		loop {
			if let Some(result) = self.released.borrow().clone() {
				return result;
			}
			self.released.changed().await.unwrap();
		}
	}
}

#[tokio::test]
async fn publisher_joins_close_and_preserves_failure_after_open_or_setup_failure() {
	rooms_testing::local_set::run(async {
		for setup in [Ok(()), Err(Error::closed("setup refused"))] {
			let opens = setup.is_ok();
			let said = Rc::new(RefCell::new(Vec::new()));
			let (opened, mut opening) = watch::channel(false);
			let (closing, mut retirement) = watch::channel(false);
			let (release, released) = watch::channel(None);
			let publisher = Publisher::start(
				Probe {
					setup,
					opened,
					closing,
					released,
					said: said.clone(),
				},
				"ws://localhost/trace".into(),
				"synthetic".into(),
				Rc::new(|_| {}),
				Rc::new(|_| {}),
			);
			opening.wait_for(|opened| *opened).await.unwrap();
			let closing = publisher.clone();
			let close = tokio::task::spawn_local(async move { closing.close().await });
			retirement.wait_for(|closing| *closing).await.unwrap();
			assert!(!close.is_finished(), "close returned before socket retirement");
			release.send_replace(Some(Err(Error::storage_message("physical close failed"))));
			let failure = close.await.unwrap().expect_err("close must report socket retirement");
			assert!(
				matches!(failure, Error::Storage(_)),
				"the adapter's own I/O failure reaches the caller as one, not as a refusal"
			);
			assert_eq!(failure.to_string(), "physical close failed");
			release.send_replace(None);
			let close = tokio::task::spawn_local(async move { publisher.close().await });
			tokio::task::yield_now().await;
			assert!(!close.is_finished(), "retry must retain the original socket barrier");
			release.send_replace(Some(Ok(())));
			close.await.unwrap().unwrap();
			let expected: &[&str] = if opens {
				&["ws://localhost/trace", "synthetic"]
			} else {
				&["ws://localhost/trace"]
			};
			assert_eq!(
				*said.borrow(),
				expected,
				"the swiss is the first message on an open socket, never the route"
			);
		}
	})
	.await;
}
