//! Diagnostic-only TCP forwarding. The Host trace intentionally skips control
//! frames, so this observer counts the outer Syrup record arm on every frame.
//! No proxy, buffer, parser, or observation task exists in the timing pass.
use glowcap::{Host, Locator, tcp};
use std::{cell::RefCell, collections::BTreeMap, rc::Rc};
use tokio::{
	io::{AsyncReadExt, AsyncWriteExt},
	net::{
		TcpListener, TcpStream,
		tcp::{OwnedReadHalf, OwnedWriteHalf},
	},
};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Counts {
	pub arms: BTreeMap<String, usize>,
	pub frames: usize,
	pub codec_bytes: usize,
}
#[derive(Default)]
struct State {
	enabled: bool,
	closing: bool,
	counts: Counts,
}
pub struct Observer {
	state: Rc<RefCell<State>>,
	forwarding: tokio::task::JoinHandle<()>,
}
impl Observer {
	pub async fn open(host: &Host, client: &Host) -> (crate::connection::Pair, Self) {
		let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
		let port = listener.local_addr().unwrap().port();
		let state = Rc::new(RefCell::new(State::default()));
		let captured = state.clone();
		let mut forwarding = None;
		let pair = crate::connection::Pair::open_routed(host, client, |upstream: Locator| {
			forwarding = Some(tokio::task::spawn_local(async move {
				let (incoming, _) = listener.accept().await.unwrap();
				let outgoing = TcpStream::connect(&upstream.designator).await.unwrap();
				incoming.set_nodelay(true).unwrap();
				outgoing.set_nodelay(true).unwrap();
				let (a_read, a_write) = incoming.into_split();
				let (b_read, b_write) = outgoing.into_split();
				tokio::try_join!(
					forward(a_read, b_write, "client", captured.clone()),
					forward(b_read, a_write, "server", captured)
				)
				.unwrap();
			}));
			tcp::locator("127.0.0.1", port)
		})
		.await;
		(
			pair,
			Self {
				state,
				forwarding: forwarding.unwrap(),
			},
		)
	}
	pub fn start(&self) {
		let mut state = self.state.borrow_mut();
		state.counts = Counts::default();
		state.enabled = true;
	}
	pub fn closing(&self) {
		self.state.borrow_mut().closing = true;
	}
	pub async fn close(self) -> Counts {
		self.forwarding.await.unwrap();
		std::mem::take(&mut self.state.borrow_mut().counts)
	}
}

async fn forward(
	mut read: OwnedReadHalf,
	mut write: OwnedWriteHalf,
	direction: &str,
	state: Rc<RefCell<State>>,
) -> std::io::Result<()> {
	let mut writing = true;
	loop {
		let mut prefix = Vec::with_capacity(12);
		loop {
			let mut byte = [0];
			if read.read(&mut byte).await? == 0 {
				assert!(prefix.is_empty(), "truncated TCP frame prefix");
				if writing {
					write.shutdown().await?;
				}
				return Ok(());
			}
			prefix.push(byte[0]);
			assert!(prefix.len() <= 12, "oversized TCP frame prefix");
			if byte[0] == b':' {
				break;
			}
			assert!(byte[0].is_ascii_digit());
		}
		let length: usize = std::str::from_utf8(&prefix[..prefix.len() - 1])
			.unwrap()
			.parse()
			.unwrap();
		assert!((1..=1024 * 1024).contains(&length));
		let mut frame = vec![0; length];
		read.read_exact(&mut frame).await?;
		{
			let mut state = state.borrow_mut();
			if state.enabled {
				let arm = arm(&frame);
				*state.counts.arms.entry(format!("{direction}:{arm}")).or_default() += 1;
				state.counts.frames += 1;
				state.counts.codec_bytes += frame.len();
			}
		}
		if writing {
			let result = async {
				write.write_all(&prefix).await?;
				write.write_all(&frame).await
			}
			.await;
			if let Err(error) = result {
				// Cancel may close the receiver before its peer's queued GC
				// arrives. Still drain and count that sender through EOF.
				if state.borrow().closing
					&& matches!(
						error.kind(),
						std::io::ErrorKind::BrokenPipe | std::io::ErrorKind::ConnectionReset
					) {
					writing = false;
				} else {
					return Err(error);
				}
			}
		}
	}
}

fn arm(frame: &[u8]) -> &str {
	assert_eq!(frame[0], b'<');
	let delimiter = frame
		.iter()
		.position(|byte| *byte == b'\'')
		.expect("Syrup record has a symbol label");
	let length: usize = std::str::from_utf8(&frame[1..delimiter]).unwrap().parse().unwrap();
	let label = std::str::from_utf8(&frame[delimiter + 1..delimiter + 1 + length]).unwrap();
	assert!(label.starts_with("op:"));
	label
}
