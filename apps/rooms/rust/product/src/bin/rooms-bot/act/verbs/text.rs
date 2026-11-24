//! Reading `--text -` spends the verb's budget before it takes an action place.
use super::{Error, Request, Turn, failure};
use std::io::Read;
use tokio::sync::oneshot;
use tokio::time::Instant;

const MAX_TEXT_BYTES: usize = rooms_application::room::line::MAX_LINE_BYTES;

pub(super) async fn read(request: &Request, turn: &Turn) -> Result<Option<String>, Error> {
	match request.single("text")? {
		Some("-") => stdin(std::io::stdin(), turn.budget.main_end).await.map(Some),
		other => Ok(other.map(str::to_owned)),
	}
}

async fn stdin(reader: impl Read + Send + 'static, until: Instant) -> Result<String, Error> {
	// A terminal or pipe may never close. A Tokio blocking read would keep its
	// runtime waiting at shutdown. This verb's process owns the reader thread
	// and exits with its deadline even while a writer still has the pipe open.
	let (send, receive) = oneshot::channel();
	std::thread::Builder::new()
		.spawn(move || {
			let mut bytes = Vec::new();
			let read = reader.take(MAX_TEXT_BYTES as u64 + 1).read_to_end(&mut bytes);
			let _ = send.send(read.map(|_| bytes));
		})
		.map_err(Error::io("starting the standard input reader"))?;
	let bytes = tokio::time::timeout_at(until, receive)
		.await
		.map_err(|_| failure::nothing_sent())?
		.map_err(|_| Error::Usage("the standard input reader stopped before it returned any text".into()))?
		.map_err(Error::io("reading --text from standard input"))?;
	if bytes.len() > MAX_TEXT_BYTES {
		return Err(Error::Usage(format!(
			"--text - read more than the {MAX_TEXT_BYTES} bytes a line holds"
		)));
	}
	let mut text = String::from_utf8(bytes).map_err(|_| Error::Usage("--text - read text that is not UTF-8".into()))?;
	if text.ends_with('\n') {
		text.pop();
	}
	Ok(text)
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::{os::unix::net::UnixStream, time::Duration};

	#[tokio::test]
	async fn an_open_input_pipe_spends_the_budget_without_sending() {
		let (read, _writer) = UnixStream::pair().unwrap();
		let result = stdin(read, Instant::now() + Duration::from_millis(10)).await;
		assert!(result.unwrap_err().to_string().contains("nothing was sent"));
	}
}
