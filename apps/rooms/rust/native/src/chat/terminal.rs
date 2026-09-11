//! Two bounded terminal workers. Nonblocking descriptors plus a wake socket
//! make signal shutdown independent of another keystroke or a stdout reader.
use nix::{
	fcntl::{fcntl, FcntlArg, OFlag},
	poll::{poll, PollFd, PollFlags},
};
use rooms_runtime::cleanup;
use std::{
	fs::File,
	io::{Read, Write},
	os::{
		fd::{AsFd, AsRawFd},
		unix::net::UnixStream,
	},
	thread::JoinHandle,
	time::{Duration, Instant},
};
use tokio::sync::mpsc;
pub const MAX_INPUT: usize = rooms_application::room::line::MAX_LINE_BYTES;
const MAX_OUTPUT: usize = 64 * 1024;

struct Descriptor {
	file: File,
	flags: Option<OFlag>,
}
impl Descriptor {
	fn new(file: File) -> Result<Self, String> {
		let flags = OFlag::from_bits_truncate(fcntl(file.as_raw_fd(), FcntlArg::F_GETFL).map_err(|e| e.to_string())?);
		fcntl(file.as_raw_fd(), FcntlArg::F_SETFL(flags | OFlag::O_NONBLOCK)).map_err(|e| e.to_string())?;
		Ok(Self {
			file,
			flags: Some(flags),
		})
	}
}
impl Drop for Descriptor {
	fn drop(&mut self) {
		let _ = self.restore();
	}
}
impl Descriptor {
	fn restore(&mut self) -> Result<(), String> {
		if let Some(flags) = self.flags.take() {
			fcntl(self.file.as_raw_fd(), FcntlArg::F_SETFL(flags)).map_err(|e| e.to_string())?;
		}
		Ok(())
	}
}

fn wait(file: &File, wake: &UnixStream, output: bool, stopping: &mut Option<Instant>) -> Result<bool, String> {
	loop {
		let timeout = if let Some(deadline) = stopping {
			let remaining = deadline.saturating_duration_since(Instant::now());
			if remaining.is_zero() {
				return Err("terminal output did not drain within two seconds".into());
			}
			remaining.as_millis().min(i32::MAX as u128) as i32
		} else {
			-1
		};
		let mut descriptors = [
			PollFd::new(
				file.as_raw_fd(),
				if output { PollFlags::POLLOUT } else { PollFlags::POLLIN },
			),
			PollFd::new(
				wake.as_raw_fd(),
				if stopping.is_none() {
					PollFlags::POLLIN
				} else {
					PollFlags::empty()
				},
			),
		];
		let count = if stopping.is_some() { 1 } else { 2 };
		match poll(&mut descriptors[..count], timeout) {
			Err(nix::errno::Errno::EINTR) => continue,
			Err(error) => return Err(error.to_string()),
			Ok(_) => {}
		}
		if stopping.is_none() && descriptors[1].revents().is_some_and(|events| !events.is_empty()) {
			if !output {
				return Ok(false);
			}
			*stopping = Some(Instant::now() + Duration::from_secs(2));
			continue;
		}
		if descriptors[0].revents().is_some_and(|events| !events.is_empty()) {
			return Ok(true);
		}
	}
}
pub struct Terminal {
	input_mode: Descriptor,
	output_mode: Descriptor,
	input: mpsc::Receiver<Result<String, String>>,
	output: mpsc::Sender<String>,
	input_wake: UnixStream,
	output_wake: UnixStream,
	reader: JoinHandle<Result<(), String>>,
	writer: JoinHandle<Result<(), String>>,
}
impl Terminal {
	pub fn open() -> Result<Self, String> {
		let input = File::from(
			std::io::stdin()
				.as_fd()
				.try_clone_to_owned()
				.map_err(|e| e.to_string())?,
		);
		let output = File::from(
			std::io::stdout()
				.as_fd()
				.try_clone_to_owned()
				.map_err(|e| e.to_string())?,
		);
		let input = Descriptor::new(input)?;
		let output = Descriptor::new(output)?;
		let (input_wake, read_wake) = UnixStream::pair().map_err(|e| e.to_string())?;
		let (output_wake, write_wake) = UnixStream::pair().map_err(|e| e.to_string())?;
		let (incoming, received) = mpsc::channel(8);
		let (send, outgoing) = mpsc::channel(32);
		let reader_file = input.file.try_clone().map_err(|e| e.to_string())?;
		let writer_file = output.file.try_clone().map_err(|e| e.to_string())?;
		let reader = std::thread::spawn(move || read(reader_file, read_wake, incoming));
		let writer = std::thread::spawn(move || write(writer_file, write_wake, outgoing));
		Ok(Self {
			input_mode: input,
			output_mode: output,
			input: received,
			output: send,
			input_wake,
			output_wake,
			reader,
			writer,
		})
	}
	pub async fn next(&mut self) -> Option<Result<String, String>> {
		self.input.recv().await
	}
	pub async fn print(&self, text: String) -> Result<(), String> {
		if text.len() > MAX_OUTPUT {
			return Err("terminal output exceeds its 64 KiB record budget".into());
		}
		let mut escaped = String::with_capacity(text.len());
		for c in text.chars() {
			if c.is_control() && c != '\n' && c != '\t' {
				escaped.extend(c.escape_default());
			} else {
				escaped.push(c);
			}
			if escaped.len() > MAX_OUTPUT {
				return Err("escaped terminal output exceeds its 64 KiB record budget".into());
			}
		}
		self.output
			.send(escaped)
			.await
			.map_err(|_| "terminal output closed".into())
	}
	pub async fn close(self) -> Result<(), String> {
		let Self {
			mut input_mode,
			mut output_mode,
			input,
			output,
			mut input_wake,
			mut output_wake,
			reader,
			writer,
		} = self;
		drop(input);
		drop(output);
		let mut result = wake(&mut input_wake);
		cleanup::retain(&mut result, wake(&mut output_wake));
		let joined = tokio::task::spawn_blocking(move || {
			let read = reader
				.join()
				.map_err(|_| "terminal reader panicked".to_owned())
				.and_then(|v| v);
			let write = writer
				.join()
				.map_err(|_| "terminal writer panicked".to_owned())
				.and_then(|v| v);
			cleanup::combine(read, write)
		})
		.await
		.map_err(|e| e.to_string())
		.and_then(|v| v);
		cleanup::retain(&mut result, joined);
		// Both workers have ended before restoring flags. Restore in reverse
		// acquisition order: stdin/stdout may share one open-file description.
		cleanup::retain(&mut result, output_mode.restore());
		cleanup::retain(&mut result, input_mode.restore());
		result
	}
}
fn read(mut input: File, wake: UnixStream, send: mpsc::Sender<Result<String, String>>) -> Result<(), String> {
	let mut line = Vec::with_capacity(MAX_INPUT);
	let mut overflow = false;
	let mut bytes = [0; 4096];
	while wait(&input, &wake, false, &mut None)? {
		let count = match input.read(&mut bytes) {
			Ok(count) => count,
			Err(e)
				if matches!(
					e.kind(),
					std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
				) =>
			{
				continue
			}
			Err(e) => return Err(e.to_string()),
		};
		if count == 0 {
			if !line.is_empty() || overflow {
				let _ = send.blocking_send(decode(&line, overflow));
			}
			return Ok(());
		}
		for byte in &bytes[..count] {
			if *byte == b'\n' {
				if send.blocking_send(decode(&line, overflow)).is_err() {
					return Ok(());
				}
				line.clear();
				overflow = false;
			} else if line.len() < MAX_INPUT {
				line.push(*byte);
			} else {
				overflow = true;
			}
		}
	}
	Ok(())
}
fn decode(line: &[u8], overflow: bool) -> Result<String, String> {
	if overflow {
		return Err("typed line exceeds 8192 bytes".into());
	}
	std::str::from_utf8(line)
		.map(|s| s.trim().to_owned())
		.map_err(|_| "typed line is not UTF-8".into())
}
fn write(mut output: File, wake: UnixStream, mut receive: mpsc::Receiver<String>) -> Result<(), String> {
	let mut stopping = None;
	while let Some(mut record) = receive.blocking_recv() {
		record.push('\n');
		let mut bytes = record.as_bytes();
		while !bytes.is_empty() {
			wait(&output, &wake, true, &mut stopping)?;
			match output.write(bytes) {
				Ok(0) => return Err("terminal output stopped accepting bytes".into()),
				Ok(count) => bytes = &bytes[count..],
				Err(e)
					if matches!(
						e.kind(),
						std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
					) => {}
				Err(e) => return Err(e.to_string()),
			}
		}
	}
	Ok(())
}

fn wake(socket: &mut UnixStream) -> Result<(), String> {
	match socket.write_all(&[1]) {
		Ok(()) => Ok(()),
		Err(error) if error.kind() == std::io::ErrorKind::BrokenPipe => Ok(()),
		Err(error) => Err(error.to_string()),
	}
}
