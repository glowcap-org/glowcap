//! The readiness lines a serving process prints on stdout. Whoever started the
//! process reads them and may close the pipe once it has the line it waited
//! for, so a refused write is that reader's choice. The caller reports it and
//! keeps serving.
use std::io::Write;

/// Write `text` and a final newline to stdout in one write.
pub fn announce(text: &str) -> std::io::Result<()> {
	let mut out = std::io::stdout().lock();
	out.write_all(format!("{text}\n").as_bytes())?;
	out.flush()
}
