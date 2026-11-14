//! Bounded, presentation-neutral reading of message Markdown.
//!
//! Messages retain their authored source on the wire and in archives. This
//! module derives a safe document for every consumer, so CommonMark semantics,
//! link authority, extension tokenization, and degradation have one owner.
use alloc::{collections::BTreeMap, string::String, vec, vec::Vec};
use markdown::{ParseOptions, mdast};
use serde::Serialize;
use url::Url;

mod extensions;
use extensions::{extensions, spoilers};

const DOCUMENT_VERSION: u8 = 1;
pub const MAX_SOURCE_BYTES: usize = 8_192;
pub const MAX_NODES: usize = 4_096;
pub const MAX_DEPTH: usize = 64;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Document {
	pub version: u8,
	pub blocks: Vec<Node>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub degraded: Option<Degradation>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Degradation {
	SourceTooLarge,
	ParserRefused,
	DocumentTooComplex,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Alignment {
	Left,
	Center,
	Right,
	None,
}

/// Rooms' stable document vocabulary. Third-party parser types never cross the
/// application boundary, and no variant can carry executable markup.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Node {
	Text {
		text: String,
	},
	Group {
		children: Vec<Node>,
	},
	Mention {
		name: String,
		room: bool,
	},
	Spoiler {
		children: Vec<Node>,
	},
	Paragraph {
		children: Vec<Node>,
	},
	Heading {
		level: u8,
		children: Vec<Node>,
	},
	BlockQuote {
		children: Vec<Node>,
	},
	List {
		ordered: bool,
		start: Option<u32>,
		children: Vec<Node>,
	},
	ListItem {
		checked: Option<bool>,
		children: Vec<Node>,
	},
	Emphasis {
		children: Vec<Node>,
	},
	Strong {
		children: Vec<Node>,
	},
	Delete {
		children: Vec<Node>,
	},
	/// `opens` is where the link goes, for a label that does not say.
	Link {
		destination: String,
		opens: Option<String>,
		title: Option<String>,
		children: Vec<Node>,
	},
	Image {
		destination: Option<String>,
		opens: Option<String>,
		title: Option<String>,
		alt: String,
	},
	InlineCode {
		text: String,
	},
	CodeBlock {
		language: Option<String>,
		text: String,
	},
	Break {
		hard: bool,
	},
	ThematicBreak,
	Table {
		alignments: Vec<Alignment>,
		children: Vec<Node>,
	},
	TableRow {
		children: Vec<Node>,
	},
	TableCell {
		children: Vec<Node>,
	},
	FootnoteDefinition {
		identifier: String,
		children: Vec<Node>,
	},
	FootnoteReference {
		identifier: String,
	},
}

#[derive(Clone)]
struct Definition {
	destination: String,
	title: Option<String>,
}

struct Projection<'a> {
	source: &'a str,
	definitions: BTreeMap<String, Definition>,
	nodes: usize,
}

impl Document {
	/// Parse CommonMark with GFM tables, tasks, references, autolinks,
	/// strikethrough, and footnotes. Every refusal becomes literal readable text.
	#[must_use]
	pub fn read(source: &str) -> Self {
		if source.len() > MAX_SOURCE_BYTES {
			return Self::literal(source, Degradation::SourceTooLarge);
		}
		let Ok(ast) = markdown::to_mdast(source, &ParseOptions::gfm()) else {
			return Self::literal(source, Degradation::ParserRefused);
		};
		if !within_limits(&ast) {
			return Self::literal(source, Degradation::DocumentTooComplex);
		}
		let mut projection = Projection {
			source,
			definitions: definitions(&ast),
			nodes: 0,
		};
		match projection.children_of(&ast, 0) {
			Ok(blocks) => Self {
				version: DOCUMENT_VERSION,
				blocks,
				degraded: None,
			},
			Err(()) => Self::literal(source, Degradation::DocumentTooComplex),
		}
	}

	fn literal(source: &str, why: Degradation) -> Self {
		Self {
			version: DOCUMENT_VERSION,
			blocks: vec![Node::Text {
				text: String::from(source),
			}],
			degraded: Some(why),
		}
	}

	#[must_use]
	pub fn mentions(&self, nick: &str) -> bool {
		let nick = nick.to_lowercase();
		let mut pending: Vec<&Node> = self.blocks.iter().collect();
		while let Some(node) = pending.pop() {
			if let Node::Mention { name, room } = node
				&& (*room || (!nick.is_empty() && name.to_lowercase() == nick))
			{
				return true;
			}
			if let Some(children) = node.children() {
				pending.extend(children);
			}
		}
		false
	}
}

impl Node {
	pub(crate) fn children(&self) -> Option<&[Self]> {
		match self {
			Self::Group { children }
			| Self::Spoiler { children }
			| Self::Paragraph { children }
			| Self::Heading { children, .. }
			| Self::BlockQuote { children }
			| Self::List { children, .. }
			| Self::ListItem { children, .. }
			| Self::Emphasis { children }
			| Self::Strong { children }
			| Self::Delete { children }
			| Self::Link { children, .. }
			| Self::Table { children, .. }
			| Self::TableRow { children }
			| Self::TableCell { children }
			| Self::FootnoteDefinition { children, .. } => Some(children),
			_ => None,
		}
	}
}

fn within_limits(root: &mdast::Node) -> bool {
	let mut pending = vec![(root, 0_usize)];
	let mut count = 0_usize;
	while let Some((node, depth)) = pending.pop() {
		count += 1;
		if count > MAX_NODES || depth > MAX_DEPTH {
			return false;
		}
		if let Some(children) = node.children() {
			pending.extend(children.iter().map(|child| (child, depth + 1)));
		}
	}
	true
}

fn definitions(root: &mdast::Node) -> BTreeMap<String, Definition> {
	let mut found = BTreeMap::new();
	let mut pending = vec![root];
	while let Some(node) = pending.pop() {
		if let mdast::Node::Definition(value) = node {
			found.insert(
				value.identifier.clone(),
				Definition {
					destination: value.url.clone(),
					title: value.title.clone(),
				},
			);
		}
		if let Some(children) = node.children() {
			pending.extend(children);
		}
	}
	found
}

impl Projection<'_> {
	fn bump(&mut self) -> Result<(), ()> {
		self.nodes += 1;
		(self.nodes <= MAX_NODES).then_some(()).ok_or(())
	}

	fn children(&mut self, children: &[mdast::Node], depth: usize) -> Result<Vec<Node>, ()> {
		let mut out = Vec::new();
		for child in children {
			if let Some(node) = self.node(child, depth + 1)? {
				out.push(node);
			}
		}
		spoilers(out, &mut self.nodes)
	}

	fn children_of(&mut self, node: &mdast::Node, depth: usize) -> Result<Vec<Node>, ()> {
		self.children(node.children().map_or(&[], Vec::as_slice), depth)
	}

	fn parent(
		&mut self,
		children: &[mdast::Node],
		depth: usize,
		make: impl FnOnce(Vec<Node>) -> Node,
	) -> Result<Option<Node>, ()> {
		self.bump()?;
		Ok(Some(make(self.children(children, depth)?)))
	}

	#[allow(clippy::too_many_lines)]
	fn node(&mut self, node: &mdast::Node, depth: usize) -> Result<Option<Node>, ()> {
		if depth > MAX_DEPTH {
			return Err(());
		}
		match node {
			mdast::Node::Root(value) => self.parent(&value.children, depth, |children| Node::Group { children }),
			mdast::Node::Paragraph(value) => {
				self.parent(&value.children, depth, |children| Node::Paragraph { children })
			}
			mdast::Node::Heading(value) => self.parent(&value.children, depth, |children| Node::Heading {
				level: value.depth,
				children,
			}),
			mdast::Node::Blockquote(value) => {
				self.parent(&value.children, depth, |children| Node::BlockQuote { children })
			}
			mdast::Node::List(value) => {
				let ordered = value.ordered;
				let start = value.start;
				self.parent(&value.children, depth, |children| Node::List {
					ordered,
					start,
					children,
				})
			}
			mdast::Node::ListItem(value) => {
				let checked = value.checked;
				self.parent(&value.children, depth, |children| Node::ListItem { checked, children })
			}
			mdast::Node::Emphasis(value) => self.parent(&value.children, depth, |children| Node::Emphasis { children }),
			mdast::Node::Strong(value) => self.parent(&value.children, depth, |children| Node::Strong { children }),
			mdast::Node::Delete(value) => self.parent(&value.children, depth, |children| Node::Delete { children }),
			mdast::Node::Link(value) => self.link(&value.url, value.title.clone(), &value.children, depth),
			mdast::Node::LinkReference(value) => {
				if let Some(definition) = self.definitions.get(&value.identifier).cloned() {
					self.link(&definition.destination, definition.title, &value.children, depth)
				} else {
					self.parent(&value.children, depth, |children| Node::Group { children })
				}
			}
			mdast::Node::Image(value) => self.image(&value.url, value.title.clone(), value.alt.clone()),
			mdast::Node::ImageReference(value) => {
				let (destination, title) = self.definitions.get(&value.identifier).map_or_else(
					|| (String::new(), None),
					|item| (item.destination.clone(), item.title.clone()),
				);
				self.image(&destination, title, value.alt.clone())
			}
			mdast::Node::InlineCode(value) => self.leaf(Node::InlineCode {
				text: value.value.clone(),
			}),
			mdast::Node::Code(value) => self.leaf(Node::CodeBlock {
				language: value.lang.clone(),
				text: value.value.clone(),
			}),
			mdast::Node::Break(_) => self.leaf(Node::Break { hard: true }),
			mdast::Node::ThematicBreak(_) => self.leaf(Node::ThematicBreak),
			mdast::Node::Text(value) => self.text(&value.value),
			// Raw HTML is one inert literal. Passing it through Rooms extensions
			// would let an attribute such as `data-owner="@zoe"` acquire mention
			// effects even though none of the HTML receives presentation authority.
			mdast::Node::Html(value) => self.leaf(Node::Text {
				text: value.value.clone(),
			}),
			mdast::Node::Table(value) => {
				let alignments = value
					.align
					.iter()
					.map(|alignment| match alignment {
						mdast::AlignKind::Left => Alignment::Left,
						mdast::AlignKind::Center => Alignment::Center,
						mdast::AlignKind::Right => Alignment::Right,
						mdast::AlignKind::None => Alignment::None,
					})
					.collect();
				self.parent(&value.children, depth, |children| Node::Table { alignments, children })
			}
			mdast::Node::TableRow(value) => self.parent(&value.children, depth, |children| Node::TableRow { children }),
			mdast::Node::TableCell(value) => {
				self.parent(&value.children, depth, |children| Node::TableCell { children })
			}
			mdast::Node::FootnoteDefinition(value) => {
				let identifier = value.identifier.clone();
				self.parent(&value.children, depth, |children| Node::FootnoteDefinition {
					identifier,
					children,
				})
			}
			mdast::Node::FootnoteReference(value) => self.leaf(Node::FootnoteReference {
				identifier: value.identifier.clone(),
			}),
			mdast::Node::Definition(_) => Ok(None),
			// GFM options do not produce MDX, frontmatter, or math nodes. If a
			// future parser version does, retain their source as text rather than
			// silently granting the new construct presentation authority.
			_ => self.literal_node(node),
		}
	}

	fn leaf(&mut self, node: Node) -> Result<Option<Node>, ()> {
		self.bump()?;
		Ok(Some(node))
	}

	fn link(
		&mut self,
		destination: &str,
		title: Option<String>,
		children: &[mdast::Node],
		depth: usize,
	) -> Result<Option<Node>, ()> {
		let children = self.children(children, depth)?;
		let Some(address) = safe_destination(destination) else {
			self.bump()?;
			return Ok(Some(Node::Group { children }));
		};
		let mut label = String::new();
		let words = said(&children, &mut label);
		self.leaf(Node::Link {
			destination: String::from(destination),
			opens: opens(&address, words.then_some(&label)),
			title,
			children,
		})
	}

	fn image(&mut self, destination: &str, title: Option<String>, alt: String) -> Result<Option<Node>, ()> {
		let address = safe_destination(destination);
		// An image with no words of its own is labelled with its destination.
		let label = if alt.is_empty() { destination } else { &alt };
		self.leaf(Node::Image {
			opens: address.as_ref().and_then(|address| opens(address, Some(label))),
			destination: address.map(|_| String::from(destination)),
			title,
			alt,
		})
	}

	fn literal_node(&mut self, node: &mdast::Node) -> Result<Option<Node>, ()> {
		let text = node
			.position()
			.and_then(|position| self.source.get(position.start.offset..position.end.offset))
			.unwrap_or_default();
		self.text(text)
	}

	fn text(&mut self, text: &str) -> Result<Option<Node>, ()> {
		let nodes = extensions(text, &mut self.nodes)?;
		if nodes.len() == 1 {
			Ok(nodes.into_iter().next())
		} else {
			self.bump()?;
			Ok(Some(Node::Group { children: nodes }))
		}
	}
}

/// An address a link may open: a web address or a mail link, written so that
/// the page's browser reads the place this parse read.
fn safe_destination(value: &str) -> Option<Url> {
	let parsed = Url::parse(value).ok()?;
	let safe = match parsed.scheme() {
		// Without `//` after its scheme, a browser reads a web address as a
		// path on the page's own host.
		"http" | "https" => value
			.get(parsed.scheme().len()..)
			.is_some_and(|written| written.starts_with("://")),
		// A mail link's place is the mailbox in its path. One written with a
		// host has none. Its query may fill in a subject and a body, and holds
		// nothing a mail program could read as a recipient the mailbox does not show.
		"mailto" => {
			!parsed.has_authority()
				&& !parsed.path().is_empty()
				&& parsed.fragment().is_none()
				&& parsed.query_pairs().all(|(field, _)| {
					["subject", "body"]
						.iter()
						.any(|filled| field.eq_ignore_ascii_case(filled))
				})
		}
		_ => false,
	};
	safe.then_some(parsed)
}

/// Where an address leads: the host of a web address, with its port when
/// that is not the scheme's own, or the mailbox of a `mailto`.
fn place(address: &Url) -> Option<String> {
	if address.scheme() == "mailto" {
		return Some(String::from(address.path()));
	}
	let host = address.host_str()?;
	Some(match address.port() {
		Some(port) => alloc::format!("{host}:{port}"),
		None => String::from(host),
	})
}

/// The place a link opens, for the reader to see beside a label that does not
/// say it. A label is the author's words, and "example.com" over a link to
/// another host is the oldest lie a link tells. `None` when the label is
/// words that read as an address at that place, with no user name or password
/// before the host. A pasted address in ASCII is such a label. One whose host
/// has letters outside ASCII shows its encoded host, because two scripts can
/// draw the same word. `label` is `None` when the label shows more than words.
fn opens(destination: &Url, label: Option<&str>) -> Option<String> {
	let place = place(destination)?;
	let mailbox = destination.scheme() == "mailto";
	let says = label.map(str::trim).is_some_and(|label| {
		label.to_ascii_lowercase().contains(&place.to_ascii_lowercase())
			&& [
				Url::parse(label),
				Url::parse(&alloc::format!("https://{label}")),
				Url::parse(&alloc::format!("mailto:{label}")),
			]
			.iter()
			.flatten()
			.any(|read| {
				(read.scheme() == "mailto") == mailbox
					&& read.username().is_empty()
					&& read.password().is_none()
					&& self::place(read).is_some_and(|read| read.eq_ignore_ascii_case(&place))
			})
	});
	(!says).then_some(place)
}

/// The words of a label, and whether words are all it shows. A spoiler covers
/// its words, and an image or a mention draws text of its own, so a label
/// that holds one says nothing a reader can check against the place.
fn said(nodes: &[Node], label: &mut String) -> bool {
	nodes.iter().all(|node| match node {
		Node::Text { text } | Node::InlineCode { text } => {
			label.push_str(text);
			true
		}
		Node::Emphasis { children } | Node::Strong { children } | Node::Delete { children } => said(children, label),
		_ => false,
	})
}

#[cfg(test)]
mod tests;
