//! Cutting an inventory to a page. A page is a few dozen rows whether the
//! directory holds thirty or three hundred thousand, so the search and the
//! count happen here, once, over every already-built row.
use alloc::{string::String, vec::Vec};

/// One candidate row: its lowercased search text, the row itself, and the
/// act that retires it, when one exists.
pub struct Source<T, A> {
	pub text: String,
	pub row: T,
	pub retire: Option<A>,
}

/// The search words, lowercased: every one must be a substring of a row's
/// text, in any order, in any field.
pub fn words(query: &str) -> Vec<String> {
	query
		.trim()
		.to_lowercase()
		.split_whitespace()
		.map(String::from)
		.collect()
}

pub fn matches(text: &str, words: &[String]) -> bool {
	words.iter().all(|word| text.contains(word.as_str()))
}

/// Prematched search text from the fields a row is found by.
pub fn search_text(parts: &[&str]) -> String {
	let mut text = String::new();
	for part in parts.iter().filter(|part| !part.is_empty()) {
		if !text.is_empty() {
			text.push(' ');
		}
		text.push_str(part);
	}
	text.to_lowercase()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Page<T> {
	pub rows: Vec<T>,
	/// The cursor of the next page, when the match ran past this one.
	pub next: Option<u64>,
	/// Every match, not only what was sent.
	pub total: u64,
}

/// The rows from `offset` up to `limit` among those matching `query`.
pub fn query_page<T, A>(sources: impl Iterator<Item = Source<T, A>>, query: &str, offset: u64, limit: u64) -> Page<T> {
	let words = words(query);
	let mut rows = Vec::new();
	let mut total = 0u64;
	for source in sources {
		if !matches(&source.text, &words) {
			continue;
		}
		if total >= offset && (rows.len() as u64) < limit {
			rows.push(source.row);
		}
		total += 1;
	}
	let sent = offset + rows.len() as u64;
	Page {
		rows,
		next: (sent < total).then_some(sent),
		total,
	}
}

/// The first `limit` matches' acts, and the count of every match.
pub fn query_batch<T, A>(sources: impl Iterator<Item = Source<T, A>>, query: &str, limit: u64) -> (Vec<A>, u64) {
	let words = words(query);
	let mut acts = Vec::new();
	let mut total = 0u64;
	for source in sources {
		if !matches(&source.text, &words) {
			continue;
		}
		total += 1;
		if (acts.len() as u64) < limit
			&& let Some(act) = source.retire
		{
			acts.push(act);
		}
	}
	(acts, total)
}

#[cfg(test)]
mod tests {
	use super::*;
	use alloc::vec;

	fn sources() -> Vec<Source<u32, u32>> {
		(0..40)
			.map(|n| Source {
				text: search_text(&[&alloc::format!("room-{n}"), if n % 2 == 0 { "sweep" } else { "keep" }]),
				row: n,
				retire: Some(n),
			})
			.collect()
	}

	#[test]
	fn a_page_counts_every_match_and_sends_one_page() {
		let page = query_page(sources().into_iter(), "sweep", 0, 5);
		assert_eq!(page.rows, vec![0, 2, 4, 6, 8]);
		assert_eq!(page.next, Some(5));
		assert_eq!(page.total, 20);
		let last = query_page(sources().into_iter(), "sweep", 15, 32);
		assert_eq!(last.rows.len(), 5);
		assert_eq!(last.next, None);
		let two_words = query_page(sources().into_iter(), "Sweep room-1", 0, 32);
		assert_eq!(two_words.total, 5, "the even rooms among room-1x");
		let (acts, total) = query_batch(sources().into_iter(), "keep", 3);
		assert_eq!(acts, vec![1, 3, 5]);
		assert_eq!(total, 20);
	}
}
