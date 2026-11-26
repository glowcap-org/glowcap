//! An answer as the lines a conversation accepts. An answer longer than one
//! line is split on paragraph breaks, then line breaks, then characters, and
//! posted as several lines. Past [`MAX_PARTS`] lines the answer is cut, and
//! its last line says so.
use super::words::CUT_NOTICE;
use rooms_application::room::line::MAX_LINE_BYTES;

/// The most lines one answer is posted as.
pub const MAX_PARTS: usize = 8;

/// The longest front of `text` that is at most `limit` bytes and ends on a
/// character boundary.
pub fn prefix(text: &str, limit: usize) -> &str {
	text.get(..text.floor_char_boundary(limit)).unwrap_or_default()
}

/// Where to end a line of at most `limit` bytes taken from the front of
/// `text`: the last paragraph break, else the last line break, else the last
/// character that fits.
fn cut(text: &str, limit: usize) -> usize {
	let window = prefix(text, limit);
	match (window.rfind("\n\n"), window.rfind('\n')) {
		(Some(at), _) if at > 0 => at,
		(_, Some(at)) if at > 0 => at,
		_ => window.len(),
	}
}

fn split_within(answer: &str, limit: usize) -> Vec<String> {
	let mut parts = Vec::new();
	let mut rest = answer;
	while !rest.is_empty() {
		if rest.len() <= limit {
			parts.push(rest.to_owned());
			break;
		}
		if parts.len() + 1 == MAX_PARTS {
			let kept = prefix(rest, cut(rest, limit - CUT_NOTICE.len()));
			parts.push(format!("{}{CUT_NOTICE}", kept.trim_end_matches('\n')));
			break;
		}
		let (head, tail) = rest.split_at(cut(rest, limit));
		parts.push(head.trim_end_matches('\n').to_owned());
		rest = tail.trim_start_matches('\n');
	}
	parts
}

/// The lines that post `answer`, each at most one line's size and none empty.
/// An answer with nothing but whitespace has no lines.
pub fn split(answer: &str) -> Vec<String> {
	let mut parts = split_within(answer.trim(), MAX_LINE_BYTES);
	parts.retain(|part| !part.trim().is_empty());
	parts
}

#[cfg(test)]
mod tests {
	use super::*;

	fn without_breaks(text: &str) -> String {
		text.chars().filter(|c| *c != '\n').collect()
	}

	#[test]
	fn an_answer_that_fits_is_one_line_unchanged() {
		assert_eq!(split("hello\n\nthere"), ["hello\n\nthere"]);
		let full = "x".repeat(MAX_LINE_BYTES);
		assert_eq!(split(&full), [full]);
	}

	#[test]
	fn paragraphs_split_before_lines_and_lines_before_characters() {
		let paragraph = "p".repeat(5000);
		let text = format!("{paragraph}\n\n{paragraph}\n\n{paragraph}");
		assert_eq!(split(&text), [paragraph.clone(), paragraph.clone(), paragraph.clone()]);
		let line = "l".repeat(5000);
		assert_eq!(split(&format!("{line}\n{line}")), [line.clone(), line]);
	}

	#[test]
	fn a_long_unbroken_answer_splits_on_character_boundaries_and_keeps_every_character() {
		let text = "é".repeat(MAX_LINE_BYTES * 2);
		let parts = split(&text);
		assert_eq!(parts.len(), 4);
		assert!(
			parts
				.iter()
				.all(|part| part.len() <= MAX_LINE_BYTES && !part.is_empty())
		);
		assert_eq!(parts.concat(), text);
	}

	#[test]
	fn an_answer_past_the_line_count_is_cut_with_a_notice_in_the_last_line() {
		let text = (0..40)
			.map(|n| format!("{n}{}", "w".repeat(3000)))
			.collect::<Vec<_>>()
			.join("\n\n");
		let parts = split(&text);
		assert_eq!(parts.len(), MAX_PARTS);
		assert!(parts.iter().all(|part| part.len() <= MAX_LINE_BYTES));
		let last = parts.last().unwrap();
		assert!(last.ends_with(CUT_NOTICE), "{last:?}");
		let kept = without_breaks(&parts.concat().replace(CUT_NOTICE, ""));
		assert!(
			without_breaks(&text).starts_with(&kept),
			"a cut answer reordered or lost text"
		);
	}

	#[test]
	fn an_answer_with_leading_breaks_has_no_empty_line() {
		assert_eq!(split("\n\n\nhello\n\n"), ["hello"]);
		assert!(split("\n\n \n").is_empty());
		let text = format!("\n\n{}\n\n{}", "a".repeat(8000), "b".repeat(8000));
		let parts = split(&text);
		assert!(parts.iter().all(|part| !part.is_empty() && !part.starts_with('\n')));
		assert_eq!(parts.len(), 2);
	}

	#[test]
	fn only_the_breaks_between_lines_are_dropped() {
		let text = format!("{}\n\n\n{}\nend", "a".repeat(8000), "b".repeat(8000));
		let parts = split(&text);
		assert_eq!(without_breaks(&parts.concat()), without_breaks(&text));
		assert!(
			parts
				.iter()
				.all(|part| !part.starts_with('\n') && !part.ends_with('\n'))
		);
	}
}
