//! Shutdown must observe socket retirement, including failed setup.
use super::publish::{Input, Publisher, Socket, Transport};
use rooms_glowcap::client::Deadline;
use std::{future::Future, rc::Rc};
use tokio::sync::watch;

#[test]
fn publisher_replaces_viewer_path_and_capability() {
	for path in ["", "/", "/viz", "/publish", "/nested/viewer"] {
		assert_eq!(
			super::publish::publish_target(
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
	setup: Result<(), String>,
	opened: watch::Sender<bool>,
	closing: watch::Sender<bool>,
	released: watch::Receiver<Option<Result<(), String>>>,
}
impl Deadline for Probe {
	async fn within<T>(&self, _: u64, work: impl Future<Output = T>) -> Option<T> {
		Some(work.await)
	}
}
impl Transport for Probe {
	type Socket = Self;
	async fn connect(&self, _: &str) -> Result<Self, String> {
		self.opened.send_replace(true);
		Ok(self.clone())
	}
	async fn sleep(&self, _: u64) {
		std::future::pending().await
	}
}
impl Socket for Probe {
	async fn ready(&mut self) -> Result<(), String> {
		self.setup.clone()
	}
	async fn next(&mut self) -> Result<Input, String> {
		std::future::pending().await
	}
	async fn send(&mut self, _: String) -> Result<(), String> {
		Ok(())
	}
	async fn close(&mut self) -> Result<(), String> {
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
			for setup in [Ok(()), Err("setup refused".into())] {
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
					"ws://localhost/viz".into(),
					"synthetic".into(),
					Rc::new(|_| {}),
					Rc::new(|_| {}),
				);
				opening.wait_for(|opened| *opened).await.unwrap();
				let close = tokio::task::spawn_local(async move { publisher.close().await });
				retirement.wait_for(|closing| *closing).await.unwrap();
				assert!(!close.is_finished(), "close returned before socket retirement");
				release.send_replace(Some(Err("physical close failed".into())));
				assert_eq!(close.await.unwrap(), Err("physical close failed".into()));
			}
		})
		.await;
}
