//! Shutdown must observe socket retirement, including failed setup.
use super::{Input, Publisher, Socket, Transport};
use crate::Error;
use rooms_glowcap::client::Deadline;
use std::{future::Future, rc::Rc};
use tokio::sync::watch;

#[test]
fn publisher_replaces_viewer_path_and_capability() {
	for path in ["", "/", "/trace", "/publish", "/nested/viewer"] {
		assert_eq!(
			super::publish_target(
				&format!("wss://localhost:8443{path}?room=example&cap=old"),
				"replacement",
			)
			.unwrap(),
			"wss://localhost:8443/publish?room=example&cap=replacement"
		);
	}
}

#[derive(Clone)]
struct Probe {
	setup: Result<(), Error>,
	opened: watch::Sender<bool>,
	closing: watch::Sender<bool>,
	released: watch::Receiver<Option<Result<(), Error>>>,
}
impl Deadline for Probe {
	async fn within<T>(&self, _: u64, work: impl Future<Output = T>) -> Option<T> {
		Some(work.await)
	}
}
impl Transport for Probe {
	type Socket = Self;
	async fn connect(&self, _: &str) -> Result<Self, Error> {
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
	async fn send(&mut self, _: String) -> Result<(), Error> {
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
	tokio::task::LocalSet::new()
		.run_until(async {
			for setup in [Ok(()), Err(Error::closed("setup refused"))] {
				let (opened, mut opening) = watch::channel(false);
				let (closing, mut retirement) = watch::channel(false);
				let (release, released) = watch::channel(None);
				let publisher = Publisher::start(
					Probe {
						setup,
						opened,
						closing,
						released,
					},
					"ws://localhost/trace".into(),
					"synthetic".into(),
					Rc::new(|_| {}),
					Rc::new(|_| {}),
				);
				opening.wait_for(|opened| *opened).await.unwrap();
				let close = tokio::task::spawn_local(async move { publisher.close().await });
				retirement.wait_for(|closing| *closing).await.unwrap();
				assert!(!close.is_finished(), "close returned before socket retirement");
				release.send_replace(Some(Err(Error::storage_message("physical close failed"))));
				let failure = close.await.unwrap().expect_err("close must report socket retirement");
				assert!(
					matches!(failure, Error::Storage(_)),
					"the adapter's own I/O failure reaches the caller as one, not as a refusal"
				);
				assert_eq!(failure.to_string(), "physical close failed");
			}
		})
		.await;
}
