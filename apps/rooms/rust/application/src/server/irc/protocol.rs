//! IRC's bounded line grammar and casemapping. IRC is an edge protocol,
//! never a CapTP netlayer: this knows nothing about sockets, rooms,
//! capabilities, or reconnect policy. The 512-byte ceiling includes CRLF.
use alloc::{
	collections::BTreeMap,
	string::{String, ToString},
	vec::Vec,
};

pub const LINE_BYTES: usize = 512;
const MAX_PARAMS: usize = 15;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Message {
	pub tags: BTreeMap<String, Option<String>>,
	pub prefix: Option<String>,
	pub command: String,
	pub params: Vec<String>,
}

impl Message {
	/// The last parameter, the trailing one when the line had it.
	pub fn last(&self) -> Option<&str> {
		self.params.last().map(String::as_str)
	}
	pub fn param(&self, at: usize) -> Option<&str> {
		self.params.get(at).map(String::as_str)
	}
	pub fn is(&self, command: &str) -> bool {
		self.command == command
	}
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
	ForbiddenByte,
	TooLong,
	TagsWithoutCommand,
	TagKey,
	PrefixWithoutCommand,
	Prefix,
	Command,
	TooManyParams,
	ParamSpaces,
	EmptyLine,
	EndedMidLine,
	NotUtf8,
}

impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::ForbiddenByte => "IRC line contains a forbidden byte",
			Self::TooLong => "IRC line exceeds 512 bytes",
			Self::TagsWithoutCommand => "IRC tags have no command",
			Self::TagKey => "IRC tag key is malformed",
			Self::PrefixWithoutCommand => "IRC prefix has no command",
			Self::Prefix => "IRC prefix is malformed",
			Self::Command => "IRC command is malformed",
			Self::TooManyParams => "IRC line has more than 15 parameters",
			Self::ParamSpaces => "only the final IRC parameter may contain spaces",
			Self::EmptyLine => "IRC sent an empty line",
			Self::EndedMidLine => "IRC stream ended mid-line",
			Self::NotUtf8 => "IRC line is not UTF-8",
		})
	}
}
impl core::error::Error for Error {}

fn unescape_tag(value: &str) -> String {
	let mut out = String::with_capacity(value.len());
	let mut chars = value.chars();
	while let Some(c) = chars.next() {
		if c != '\\' {
			out.push(c);
			continue;
		}
		match chars.next() {
			Some(':') => out.push(';'),
			Some('r') => out.push('\r'),
			Some('n') => out.push('\n'),
			Some('s') => out.push(' '),
			Some('\\') => out.push('\\'),
			Some(other) => {
				out.push('\\');
				out.push(other);
			}
			None => out.push('\\'),
		}
	}
	out
}

fn valid_command(command: &str) -> bool {
	!command.is_empty()
		&& (command.bytes().all(|b| b.is_ascii_uppercase())
			|| (command.len() == 3 && command.bytes().all(|b| b.is_ascii_digit())))
}

/// Parse one IRC payload without its CRLF. Unknown commands and tags remain
/// data. Consumers decide which subset they understand.
pub fn parse_line(line: &str) -> Result<Message, Error> {
	if line.is_empty() || line.bytes().any(|b| matches!(b, 0 | b'\r' | b'\n')) {
		return Err(Error::ForbiddenByte);
	}
	if line.len() + 2 > LINE_BYTES {
		return Err(Error::TooLong);
	}
	let mut rest = line;
	let mut tags = BTreeMap::new();
	if let Some(tagged) = rest.strip_prefix('@') {
		let end = tagged.find(' ').ok_or(Error::TagsWithoutCommand)?;
		if end == 0 {
			return Err(Error::TagsWithoutCommand);
		}
		for field in tagged[..end].split(';') {
			let (key, value) = match field.find('=') {
				Some(at) => (&field[..at], Some(unescape_tag(&field[at + 1..]))),
				None => (field, None),
			};
			if key.is_empty()
				|| !key
					.bytes()
					.all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'+' | b'-' | b'/'))
			{
				return Err(Error::TagKey);
			}
			tags.insert(key.into(), value);
		}
		rest = &tagged[end + 1..];
	}
	let mut prefix = None;
	if let Some(prefixed) = rest.strip_prefix(':') {
		let end = prefixed.find(' ').ok_or(Error::PrefixWithoutCommand)?;
		if end == 0 {
			return Err(Error::PrefixWithoutCommand);
		}
		prefix = Some(prefixed[..end].to_string());
		rest = &prefixed[end + 1..];
	}
	let (command, after) = match rest.find(' ') {
		Some(end) => (&rest[..end], &rest[end + 1..]),
		None => (rest, ""),
	};
	let command = command.to_ascii_uppercase();
	if !valid_command(&command) {
		return Err(Error::Command);
	}
	let mut params = Vec::new();
	let mut rest = after;
	while !rest.is_empty() {
		rest = rest.trim_start_matches(' ');
		if rest.is_empty() {
			break;
		}
		if let Some(trailing) = rest.strip_prefix(':') {
			params.push(trailing.to_string());
			break;
		}
		match rest.find(' ') {
			None => {
				params.push(rest.to_string());
				break;
			}
			Some(end) => {
				params.push(rest[..end].to_string());
				rest = &rest[end + 1..];
			}
		}
	}
	if params.len() > MAX_PARAMS {
		return Err(Error::TooManyParams);
	}
	Ok(Message {
		tags,
		prefix,
		command,
		params,
	})
}

/// Encode one IRC line, including CRLF. A prefix is the server side of the
/// shared vocabulary. Bridge writes omit it. The final parameter becomes
/// trailing when its form requires it.
pub fn encode_message(command: &str, params: &[&str], prefix: Option<&str>) -> Result<Vec<u8>, Error> {
	// Refuse before allocating or copying caller text. The wire limit includes
	// separators, optional prefix, trailing marker and CRLF.
	if params.len() > MAX_PARAMS {
		return Err(Error::TooManyParams);
	}
	let mut size = command
		.len()
		.saturating_add(2)
		.saturating_add(prefix.map_or(0, |value| value.len().saturating_add(2)));
	for (at, param) in params.iter().enumerate() {
		if size > LINE_BYTES || param.len() > LINE_BYTES {
			return Err(Error::TooLong);
		}
		let trailing = at + 1 == params.len() && (param.is_empty() || param.starts_with(':') || param.contains(' '));
		size = size.saturating_add(1 + param.len() + usize::from(trailing));
	}
	if size > LINE_BYTES {
		return Err(Error::TooLong);
	}
	let upper = command.to_ascii_uppercase();
	if !valid_command(&upper) {
		return Err(Error::Command);
	}
	if let Some(prefix) = prefix
		&& (prefix.is_empty() || prefix.bytes().any(|b| matches!(b, 0 | b'\r' | b'\n' | b' ')))
	{
		return Err(Error::Prefix);
	}
	if params.len() > MAX_PARAMS {
		return Err(Error::TooManyParams);
	}
	let mut line = String::with_capacity(size);
	if let Some(prefix) = prefix {
		line.push(':');
		line.push_str(prefix);
		line.push(' ');
	}
	line.push_str(&upper);
	for (index, param) in params.iter().enumerate() {
		if param.bytes().any(|b| matches!(b, 0 | b'\r' | b'\n')) {
			return Err(Error::ForbiddenByte);
		}
		let last = index + 1 == params.len();
		let needs_trailing = param.is_empty() || param.starts_with(':') || param.contains(' ');
		if !last && needs_trailing {
			return Err(Error::ParamSpaces);
		}
		line.push(' ');
		if last && needs_trailing {
			line.push(':');
		}
		line.push_str(param);
	}
	line.push_str("\r\n");
	if line.len() > LINE_BYTES {
		return Err(Error::TooLong);
	}
	Ok(line.into_bytes())
}

/// Encode a client-to-server line: the narrow form a bridge writes, so a
/// caller cannot claim a server prefix by accident.
pub fn encode(command: &str, params: &[&str]) -> Result<Vec<u8>, Error> {
	encode_message(command, params, None)
}

/// Fold arbitrary byte chunks into complete messages while retaining only
/// one protocol-sized line. A truncated or overlong peer fails closed.
#[derive(Default)]
pub struct LineReader {
	line: Vec<u8>,
}

impl LineReader {
	/// The messages `chunk` completes, in order. The first error ends the
	/// stream: nothing after it is trusted.
	pub fn feed(&mut self, chunk: &[u8]) -> Result<Vec<Message>, Error> {
		let mut out = Vec::new();
		for &byte in chunk {
			if byte == b'\n' {
				let payload = match self.line.last() {
					Some(b'\r') => &self.line[..self.line.len() - 1],
					_ => &self.line[..],
				};
				if payload.is_empty() {
					return Err(Error::EmptyLine);
				}
				let text = core::str::from_utf8(payload).map_err(|_| Error::NotUtf8)?;
				out.push(parse_line(text)?);
				self.line.clear();
				continue;
			}
			if self.line.len() >= LINE_BYTES - 1 {
				return Err(Error::TooLong);
			}
			self.line.push(byte);
		}
		Ok(out)
	}
	/// The stream ended: a partial line is a failure.
	pub fn end(&self) -> Result<(), Error> {
		if self.line.is_empty() {
			Ok(())
		} else {
			Err(Error::EndedMidLine)
		}
	}
}

/// RFC 1459's case-insensitive nickname and channel comparison.
pub fn fold(value: &str) -> String {
	value
		.chars()
		.map(|c| match c {
			'[' => '{',
			']' => '}',
			'\\' => '|',
			'^' => '~',
			other => other.to_ascii_lowercase(),
		})
		.collect::<String>()
		.to_lowercase()
}

pub fn nick_from_prefix(prefix: Option<&str>) -> Option<&str> {
	let prefix = prefix?;
	Some(match prefix.find(['!', '@']) {
		Some(end) => &prefix[..end],
		None => prefix,
	})
}

/// Join refusal numerics name the channel after the recipient nick. Text in
/// the explanation is never a second channel to retire.
pub fn refused_channel(message: &Message) -> Option<&str> {
	match message.command.as_str() {
		"403" | "405" | "471" | "473" | "474" | "475" | "476" | "477" => message.param(1),
		_ => None,
	}
}

/// Strip the status prefixes a NAMES row puts in front of a nick.
pub fn bare_names_nick(value: &str) -> &str {
	value.trim_start_matches(['~', '&', '@', '%', '+'])
}

/// The CTCP ACTION wrapping for a `/me`: one authority for the byte form,
/// so the outbound writer and the inbound translator cannot drift.
pub fn ctcp_action(text: &str) -> String {
	alloc::format!("\u{1}ACTION {text}\u{1}")
}

/// The text inside a CTCP ACTION, or `None` when the line is ordinary. A
/// missing trailing delimiter is tolerated: some clients omit it.
pub fn ctcp_action_text(raw: &str) -> Option<&str> {
	let inner = raw.strip_prefix("\u{1}ACTION ")?;
	Some(inner.strip_suffix('\u{1}').unwrap_or(inner))
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_tagged_prefixed_line_parses_and_encodes_back() {
		let parsed = parse_line("@time=2024;x :nick!u@h PRIVMSG #room :hello there").unwrap();
		assert_eq!(parsed.tags.get("time").cloned().flatten().as_deref(), Some("2024"));
		assert_eq!(parsed.tags.get("x"), Some(&None));
		assert_eq!(parsed.prefix.as_deref(), Some("nick!u@h"));
		assert_eq!(parsed.command, "PRIVMSG");
		assert_eq!(parsed.params, ["#room", "hello there"]);
		assert_eq!(
			encode("privmsg", &["#room", "hello there"]).unwrap(),
			b"PRIVMSG #room :hello there\r\n"
		);
		assert_eq!(
			encode_message("001", &["nick", "welcome"], Some("fixture")).unwrap(),
			b":fixture 001 nick welcome\r\n"
		);
	}

	#[test]
	fn the_grammar_refuses_what_irc_refuses() {
		assert_eq!(parse_line("").unwrap_err(), Error::ForbiddenByte);
		assert_eq!(parse_line("PRIVMSG #a :\u{0}x").unwrap_err(), Error::ForbiddenByte);
		assert_eq!(parse_line("12 x").unwrap_err(), Error::Command);
		assert_eq!(parse_line("@ PRIVMSG").unwrap_err(), Error::TagsWithoutCommand);
		assert_eq!(encode("PRIVMSG", &["a b", "c"]).unwrap_err(), Error::ParamSpaces);
		let long = "x".repeat(LINE_BYTES);
		assert_eq!(parse_line(&long).unwrap_err(), Error::TooLong);
		assert_eq!(encode("PRIVMSG", &["#a", &long]).unwrap_err(), Error::TooLong);
	}

	#[test]
	fn the_reader_folds_chunks_into_lines_and_fails_closed() {
		let mut reader = LineReader::default();
		assert!(reader.feed(b"PING :a\r\nNOT").unwrap().len() == 1);
		let rest = reader.feed(b"ICE\n").unwrap();
		assert_eq!(rest[0].command, "NOTICE");
		assert!(reader.end().is_ok());
		assert_eq!(reader.feed(b"\r\n").unwrap_err(), Error::EmptyLine);
		let mut mid = LineReader::default();
		mid.feed(b"PART").unwrap();
		assert_eq!(mid.end().unwrap_err(), Error::EndedMidLine);
	}

	#[test]
	fn folding_and_prefixes_follow_rfc_1459() {
		assert_eq!(fold("Nick[]\\^"), "nick{}|~");
		assert_eq!(nick_from_prefix(Some("alice!u@example")), Some("alice"));
		assert_eq!(nick_from_prefix(Some("server.example")), Some("server.example"));
		assert_eq!(bare_names_nick("@+alice"), "alice");
		assert_eq!(ctcp_action_text(&ctcp_action("waves")), Some("waves"));
		assert_eq!(ctcp_action_text("\u{1}ACTION waves"), Some("waves"));
		assert_eq!(ctcp_action_text("waves"), None);
	}
}
