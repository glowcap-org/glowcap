//! Rooms inline vocabulary layered over Markdown's inert projection. Mentions
//! enter only through text nodes. Spoilers reconcile across sibling nodes so
//! their delimiters can contain ordinary Markdown without entering code or
//! destinations.
use super::{MAX_NODES, Node};
use alloc::{string::String, vec::Vec};

pub(super) fn extensions(text: &str, count: &mut usize) -> Result<Vec<Node>, ()> {
	let mut out = Vec::new();
	plain_extensions(text, &mut out, count)?;
	Ok(out)
}

/// Pair spoiler delimiters after Markdown children have been projected. This
/// is scoped to one parent: a delimiter cannot reach out of a
/// paragraph, emphasis span, or link and change the meaning of its sibling.
pub(super) fn spoilers(nodes: Vec<Node>, count: &mut usize) -> Result<Vec<Node>, ()> {
	let mut visible = Vec::new();
	let mut hidden: Option<Vec<Node>> = None;
	for node in nodes {
		let Node::Text { text } = node else {
			target(&mut visible, &mut hidden).push(node);
			continue;
		};
		let mut rest = text.as_str();
		let mut credited = true;
		while let Some((before, after)) = rest.split_once("||") {
			push_split_text(before, target(&mut visible, &mut hidden), count, &mut credited)?;
			if let Some(children) = hidden.take() {
				push_node(&mut visible, Node::Spoiler { children }, count)?;
			} else {
				hidden = Some(Vec::new());
			}
			rest = after;
		}
		push_split_text(rest, target(&mut visible, &mut hidden), count, &mut credited)?;
	}
	if let Some(mut unclosed) = hidden {
		push_node(
			&mut visible,
			Node::Text {
				text: String::from("||"),
			},
			count,
		)?;
		visible.append(&mut unclosed);
	}
	Ok(visible)
}

fn target<'a>(visible: &'a mut Vec<Node>, hidden: &'a mut Option<Vec<Node>>) -> &'a mut Vec<Node> {
	hidden.as_mut().unwrap_or(visible)
}

fn push_split_text(text: &str, out: &mut Vec<Node>, count: &mut usize, credited: &mut bool) -> Result<(), ()> {
	if text.is_empty() {
		return Ok(());
	}
	if *credited {
		*credited = false;
		out.push(Node::Text {
			text: String::from(text),
		});
		Ok(())
	} else {
		push_node(
			out,
			Node::Text {
				text: String::from(text),
			},
			count,
		)
	}
}

fn plain_extensions(text: &str, out: &mut Vec<Node>, count: &mut usize) -> Result<(), ()> {
	let mut plain = 0;
	let mut cursor = 0;
	while cursor < text.len() {
		let character = span(text, cursor..)?.chars().next().ok_or(())?;
		if character == '\n' {
			push_text(span(text, plain..cursor)?, out, count)?;
			push_node(out, Node::Break { hard: false }, count)?;
			cursor += 1;
			plain = cursor;
			continue;
		}
		if character == '@' && mention_starts(span(text, ..cursor)?) {
			let start = cursor + 1;
			let mut end = start;
			for candidate in span(text, start..)?.chars() {
				if !mention_character(candidate) {
					break;
				}
				end += candidate.len_utf8();
			}
			while end > start && span(text, ..end)?.ends_with('-') {
				end -= 1;
			}
			if end > start {
				push_text(span(text, plain..cursor)?, out, count)?;
				let name = span(text, start..end)?;
				push_node(
					out,
					Node::Mention {
						name: String::from(name),
						room: crate::room::inbox::addresses_everyone(name),
					},
					count,
				)?;
				cursor = end;
				plain = end;
				continue;
			}
		}
		cursor += character.len_utf8();
	}
	push_text(span(text, plain..)?, out, count)
}

/// `text` sliced by a cursor this module advances by whole characters; a
/// range that is off a boundary or out of bounds refuses instead of panicking.
fn span(text: &str, range: impl core::slice::SliceIndex<str, Output = str>) -> Result<&str, ()> {
	text.get(range).ok_or(())
}

fn mention_character(value: char) -> bool {
	value.is_alphanumeric() || value == '_' || matches!(value, '[' | ']' | '\\' | '`' | '^' | '{' | '|' | '}' | '-')
}

fn mention_starts(prefix: &str) -> bool {
	prefix.chars().next_back().is_none_or(|value| !mention_character(value))
}

fn push_text(text: &str, out: &mut Vec<Node>, count: &mut usize) -> Result<(), ()> {
	if text.is_empty() {
		return Ok(());
	}
	push_node(
		out,
		Node::Text {
			text: String::from(text),
		},
		count,
	)
}

fn push_node(out: &mut Vec<Node>, node: Node, count: &mut usize) -> Result<(), ()> {
	*count += 1;
	if *count > MAX_NODES {
		return Err(());
	}
	out.push(node);
	Ok(())
}
