//! Internal archive-listing validation shared by build.rs and its gate.

fn digits(value: &str) -> bool {
	!value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit())
}

fn iso_date(value: &str) -> bool {
	let bytes = value.as_bytes();
	bytes.len() == 10
		&& bytes[0..4].iter().all(u8::is_ascii_digit)
		&& bytes[4] == b'-'
		&& bytes[5..7].iter().all(u8::is_ascii_digit)
		&& bytes[7] == b'-'
		&& bytes[8..10].iter().all(u8::is_ascii_digit)
}

fn month(value: &str) -> bool {
	matches!(
		value,
		"Jan" | "Feb" | "Mar" | "Apr" | "May" | "Jun" | "Jul" | "Aug" | "Sep" | "Oct" | "Nov" | "Dec"
	)
}

fn clock_or_year(value: &str) -> bool {
	let bytes = value.as_bytes();
	(bytes.len() == 4 && bytes.iter().all(u8::is_ascii_digit))
		|| ((bytes.len() == 5 || bytes.len() == 8)
			&& bytes[0..2].iter().all(u8::is_ascii_digit)
			&& bytes[2] == b':'
			&& bytes[3..5].iter().all(u8::is_ascii_digit)
			&& (bytes.len() == 5 || (bytes[5] == b':' && bytes[6..8].iter().all(u8::is_ascii_digit))))
}

// The whole line is parsed, including any " -> target" tail. Stripping that
// tail here would truncate a regular file whose own name contains " -> ", and
// the traversal check would then run on a prefix of the name tar
// extracts. The caller strips it for links only, and only for the prefix test.
fn member(line: &str) -> Option<(u8, String)> {
	let parts: Vec<&str> = line.split_whitespace().collect();
	let start =
		// GNU tar: mode owner/group size YYYY-MM-DD HH:MM name...
		if parts.len() >= 6
			&& digits(parts[2])
			&& iso_date(parts[3])
			&& clock_or_year(parts[4])
		{
			5
		// BSD tar: mode links owner group size Mon DD HH:MM name...
		} else if parts.len() >= 9
			&& digits(parts[1])
			&& digits(parts[4])
			&& month(parts[5])
			&& digits(parts[6])
			&& clock_or_year(parts[7])
		{
			8
		} else {
			return None;
		};
	Some((*line.as_bytes().first()?, parts[start..].join(" ")))
}

pub fn listing_violation(listing: &str, prefix: &str) -> Option<String> {
	let prefix_slash = format!("{prefix}/");
	for line in listing.lines().filter(|line| !line.is_empty()) {
		let Some((kind, raw)) = member(line) else {
			return Some(format!(
				"unrecognized tar listing format (need GNU or BSD tar; got: {line})\n  \
				 install GNU tar, or set GLOWCAP_LIB_DIR to a directory you extracted yourself"
			));
		};
		// `tar -czf x .` stores every member as `./lib/…`. Without this the
		// prefix test below matches nothing and the whole archive passes
		// unexamined, which is not the same as passing.
		let stripped = raw.strip_prefix("./").unwrap_or(&raw);
		// A link's printed name carries its target, and tar spells the two kinds
		// differently: a symlink as `lib -> /etc`, a hard link as `lib link to real`.
		// Strip whichever tail belongs to this kind, and only for that kind, so a link
		// *named* the prefix is still recognized as being under it. Without this the
		// reconstructed name matches neither `lib` nor `lib/...`, the member is skipped
		// before the kind test, and a link named exactly `lib` is extracted as the
		// library directory. A regular file whose own name contains either separator
		// must keep its whole name, which is why the strip is conditioned on the kind.
		let separator = match kind {
			b'l' => Some(" -> "),
			b'h' => Some(" link to "),
			_ => None,
		};
		let name = match separator {
			Some(sep) => stripped.split(sep).next().unwrap_or(stripped).to_string(),
			None => stripped.to_string(),
		};
		if name != prefix && !name.starts_with(&prefix_slash) {
			continue;
		}
		if kind != b'-' && kind != b'd' {
			return Some(format!("refusing non-file tar member: {name}"));
		}
		if name.starts_with('/') || name.split('/').any(|part| part == "..") {
			return Some(format!("refusing unsafe tar member: {name}"));
		}
	}
	None
}
