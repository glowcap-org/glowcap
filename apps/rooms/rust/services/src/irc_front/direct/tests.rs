use super::*;
use crate::irc::socket::Writer;
use glowcap::{ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use std::{
	future::Future,
	io,
	pin::Pin,
	task::{Context, Poll},
	time::Duration,
};
use tokio::{io::AsyncWrite, sync::oneshot};

struct RefusingSocket {
	attempted: Option<oneshot::Sender<()>>,
	refuse: oneshot::Receiver<()>,
}
impl AsyncWrite for RefusingSocket {
	fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, _: &[u8]) -> Poll<io::Result<usize>> {
		if let Some(attempted) = self.attempted.take() {
			let _ = attempted.send(());
		}
		match Pin::new(&mut self.refuse).poll(cx) {
			Poll::Pending => Poll::Pending,
			Poll::Ready(_) => Poll::Ready(Err(io::Error::new(
				io::ErrorKind::BrokenPipe,
				"fixture socket write failed",
			))),
		}
	}
	fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
		Poll::Ready(Ok(()))
	}
	fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
		Poll::Ready(Ok(()))
	}
}
#[tokio::test]
async fn direct_acknowledgement_waits_for_the_irc_write_and_preserves_its_failure() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(5), async {
				let listener = tcp::listen("127.0.0.1", 0, Default::default()).await.unwrap();
				let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
					.await
					.unwrap();
				let locator = listener.locator().unwrap();
				let (caller, peer) =
					tokio::join!(runtime.connect(&locator, ConnectOptions::default()), listener.accept());
				let (caller, peer) = (caller.unwrap().with_gc(), peer.unwrap().with_gc());
				let (writer, pump) = Writer::open(Duration::ZERO);
				let output = Output::new(writer, "rooms.test".into(), "alice").unwrap();
				let (state, jobs) = State::new(output.clone());
				let id = Id::parse("11111111-1111-4111-8111-111111111111").unwrap();
				peer.publish("inbox", behavior(Rc::downgrade(&state), "bob".into(), id))
					.unwrap();
				let mut tasks = tokio::task::JoinSet::new();
				tasks.spawn_local(peer.serve());
				let inbox = caller.fetch("inbox").await.unwrap();
				let delivery = tokio::task::spawn_local(deliver(output, jobs, Rc::new(|_| {})));
				let (attempted, writing) = oneshot::channel();
				let (refuse, refusal) = oneshot::channel();
				let pumping = tokio::task::spawn_local(pump.run(RefusingSocket {
					attempted: Some(attempted),
					refuse: refusal,
				}));
				let send = caller.send(&inbox, "dm", &["hello".into()]);
				let send = std::future::IntoFuture::into_future(send);
				tokio::pin!(send);
				writing.await.unwrap();
				assert!(
					tokio::time::timeout(Duration::from_millis(5), &mut send).await.is_err(),
					"DM acknowledged an unwritten IRC frame"
				);
				refuse.send(()).unwrap();
				let error = send.await.unwrap_err();
				assert!(error.to_string().contains("fixture socket write failed"), "{error}");
				assert!(pumping.await.unwrap().is_err());
				drop(state);
				delivery.await.unwrap().unwrap();
				caller.close(PendingWork::Cancel).await.unwrap();
				peer.close(PendingWork::Cancel).await.unwrap();
				while let Some(ended) = tasks.join_next().await {
					ended.unwrap().unwrap();
				}
				listener.close().await.unwrap();
				runtime.close(PendingWork::Cancel).await.unwrap();
				listener.host().close(PendingWork::Cancel).await.unwrap();
			})
			.await
			.unwrap();
		})
		.await;
}
