//! Embedder-owned transport I/O. Stream adapters retain their reusable read
//! buffer. Packet adapters transfer each received message without flattening it.
use std::{
	future::Future,
	future::poll_fn,
	io,
	task::{Context, Poll},
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// One complete transport message per successful read. `None` means EOF.
/// `Some(Vec::new())` is an actual empty message for the Host to validate.
/// Pending reads consume nothing. Implementations bound their incoming queue
/// before allocation and transfer its owned message here without another copy.
pub trait PacketRead: Unpin {
	fn poll_packet(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<Option<Vec<u8>>>>;
}

/// A transport writer accepting one Host-selected packet. The optional prefix
/// precedes the body. The core leaves it empty for message-framed transports.
/// `Pending` consumes neither slice. `Ready(Ok(()))` accepts the entire packet.
/// An error after partial acceptance is terminal. Neither slice may be retained
/// after returning. `poll_flush` observes the adapter's bounded backpressure.
pub trait PacketWrite: Unpin {
	fn poll_packet(&mut self, cx: &mut Context<'_>, prefix: &[u8], body: &[u8]) -> Poll<io::Result<()>>;
	fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>>;
}

/// The physical I/O retirement barrier. The first poll interrupts the channel's
/// read/write operations. Completion means callbacks and workers are retired.
/// Failure must retain a diagnostic when the platform cannot confirm closure.
/// This owner outlives read/write halves and stays owned by the Host until its
/// result is observed. Implementations own their platform close deadline.
pub trait ChannelClose: Unpin {
	fn poll_close(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>>;
}

/// One transport's I/O and retirement authority. FFI driver providers use
/// their own driver lifecycle. This type is for embedder-owned channels.
pub struct Channel {
	pub(crate) reader: Reader,
	pub(crate) writer: Writer,
	pub(crate) close: Option<Box<dyn ChannelClose>>,
}

impl Channel {
	/// Stop this unadmitted channel and observe physical resource retirement.
	pub async fn close(self) -> io::Result<()> {
		let Self { reader, writer, close } = self;
		drop((reader, writer));
		if let Some(mut close) = close {
			catch_io_panic("channel close", poll_fn(|cx| close.poll_close(cx))).await?;
		}
		Ok(())
	}

	/// Wrap an FFI byte stream whose final Drop releases its I/O resource.
	pub fn stream<S: AsyncRead + AsyncWrite + Unpin + 'static>(stream: S) -> Self {
		let (reader, writer) = tokio::io::split(stream);
		Self {
			reader: Reader::Stream {
				source: Box::new(reader),
				scratch: Vec::new(),
			},
			writer: Writer::Stream(Box::new(writer)),
			close: None,
		}
	}

	/// Build a byte-stream channel whose read half, write half, and physical
	/// retirement have distinct owners. Protocol transports such as WebSocket
	/// use this instead of [`Channel::stream`]: dropping their byte halves stops
	/// application I/O, but only the close owner can finish the wire protocol
	/// and confirm that the underlying resource retired.
	pub fn byte_stream(
		reader: impl AsyncRead + Unpin + 'static,
		writer: impl AsyncWrite + Unpin + 'static,
		close: impl ChannelClose + 'static,
	) -> Self {
		Self {
			reader: Reader::Stream {
				source: Box::new(reader),
				scratch: Vec::new(),
			},
			writer: Writer::Stream(Box::new(writer)),
			close: Some(Box::new(close)),
		}
	}

	/// Preserve the packet boundaries supplied by a browser or other message
	/// transport, with its explicit resource-retirement authority.
	pub fn packets(
		reader: impl PacketRead + 'static,
		writer: impl PacketWrite + 'static,
		close: impl ChannelClose + 'static,
	) -> Self {
		Self {
			reader: Reader::Packets {
				source: Box::new(reader),
				packet: Vec::new(),
			},
			writer: Writer::Packets(Box::new(writer)),
			close: Some(Box::new(close)),
		}
	}

	/// Byte-stream transport with owned incoming chunks and incremental writes.
	/// Browser WebSockets can transfer an incoming message directly to the Host
	/// while limiting each outgoing write to the browser's available buffer.
	pub fn byte_chunks(
		reader: impl PacketRead + 'static,
		writer: impl AsyncWrite + Unpin + 'static,
		close: impl ChannelClose + 'static,
	) -> Self {
		Self {
			reader: Reader::Packets {
				source: Box::new(reader),
				packet: Vec::new(),
			},
			writer: Writer::Stream(Box::new(writer)),
			close: Some(Box::new(close)),
		}
	}
}

pub(crate) enum Reader {
	Stream {
		source: Box<dyn AsyncRead + Unpin>,
		scratch: Vec<u8>,
	},
	Packets {
		source: Box<dyn PacketRead>,
		packet: Vec<u8>,
	},
}

impl Reader {
	pub(crate) async fn read(&mut self) -> io::Result<Option<&[u8]>> {
		match self {
			Self::Stream { source, scratch } => {
				if scratch.is_empty() {
					scratch.resize(crate::session_shared::READ_CHUNK, 0);
				}
				let count = catch_io_panic("channel read", source.read(scratch)).await?;
				Ok((count != 0).then_some(&scratch[..count]))
			}
			Self::Packets { source, packet } => {
				match catch_io_panic("channel read", poll_fn(|cx| source.poll_packet(cx))).await? {
					Some(received) => {
						*packet = received;
						Ok(Some(packet))
					}
					None => Ok(None),
				}
			}
		}
	}
}

pub(crate) enum Writer {
	Stream(Box<dyn AsyncWrite + Unpin>),
	Packets(Box<dyn PacketWrite>),
}

impl Writer {
	pub(crate) async fn write(&mut self, prefix: &[u8], body: &[u8]) -> io::Result<()> {
		catch_io_panic("channel write", async {
			match self {
				Self::Stream(sink) => {
					sink.write_all(prefix).await?;
					sink.write_all(body).await
				}
				Self::Packets(sink) => poll_fn(|cx| sink.poll_packet(cx, prefix, body)).await,
			}
		})
		.await
	}
	pub(crate) async fn flush(&mut self) -> io::Result<()> {
		catch_io_panic("channel flush", async {
			match self {
				Self::Stream(sink) => sink.flush().await,
				Self::Packets(sink) => poll_fn(|cx| sink.poll_flush(cx)).await,
			}
		})
		.await
	}
}

/// An unwinding transport callback must return through normal I/O failure
/// handling so the Session retires and wakes observers. The future stays on
/// the stack, with no allocation or payload copy on successful polls.
pub(crate) async fn catch_io_panic<T>(
	operation: &'static str,
	future: impl Future<Output = io::Result<T>>,
) -> io::Result<T> {
	let mut future = std::pin::pin!(future);
	poll_fn(
		|cx| match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| future.as_mut().poll(cx))) {
			Ok(outcome) => outcome,
			Err(payload) => Poll::Ready(Err(io::Error::other(format!(
				"{operation} callback panicked: {}",
				crate::panic_message(payload.as_ref())
			)))),
		},
	)
	.await
}

#[cfg(test)]
mod tests {
	use super::*;

	struct Panicking;
	impl PacketRead for Panicking {
		fn poll_packet(&mut self, _cx: &mut Context<'_>) -> Poll<io::Result<Option<Vec<u8>>>> {
			panic!("packet read refused");
		}
	}
	impl PacketWrite for Panicking {
		fn poll_packet(&mut self, _cx: &mut Context<'_>, _prefix: &[u8], _body: &[u8]) -> Poll<io::Result<()>> {
			panic!("packet write refused");
		}
		fn poll_flush(&mut self, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
			panic!("packet flush refused");
		}
	}
	impl ChannelClose for Panicking {
		fn poll_close(&mut self, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
			panic!("channel close refused");
		}
	}

	#[tokio::test]
	async fn packet_callbacks_preserve_panics_as_io_failures() {
		let mut channel = Channel::packets(Panicking, Panicking, Panicking);
		assert_eq!(
			channel.reader.read().await.unwrap_err().to_string(),
			"channel read callback panicked: packet read refused"
		);
		assert_eq!(
			channel.writer.write(&[], b"body").await.unwrap_err().to_string(),
			"channel write callback panicked: packet write refused"
		);
		assert_eq!(
			channel.writer.flush().await.unwrap_err().to_string(),
			"channel flush callback panicked: packet flush refused"
		);
		assert_eq!(
			channel.close().await.unwrap_err().to_string(),
			"channel close callback panicked: channel close refused"
		);
	}
}
