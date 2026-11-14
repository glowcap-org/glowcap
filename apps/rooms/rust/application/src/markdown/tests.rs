use super::*;
use alloc::format;

fn kinds(source: &str) -> Vec<Node> {
	Document::read(source).blocks
}

fn text_in(nodes: &[Node]) -> String {
	let mut text = String::new();
	for node in nodes {
		if let Node::Text { text: part } = node {
			text.push_str(part);
		}
		if let Some(children) = node.children() {
			text.push_str(&text_in(children));
		}
	}
	text
}

#[test]
fn reads_nested_commonmark_and_gfm() {
	let document = Document::read("## Plan\n\n- [x] **ship** ~~later~~\n\n| A | B |\n| :- | -: |\n| 1 | 2 |");
	assert_eq!(document.degraded, None);
	assert!(matches!(document.blocks[0], Node::Heading { level: 2, .. }));
	assert!(matches!(document.blocks[1], Node::List { ordered: false, .. }));
	assert!(matches!(document.blocks[2], Node::Table { .. }));
}

#[test]
fn links_are_authority_only_for_deliberate_schemes() {
	let safe = kinds("[safe](https://example.com)");
	assert!(format!("{safe:?}").contains("Link"));
	let unsafe_link = kinds("[ordinary](javascript:alert(1))");
	assert!(!format!("{unsafe_link:?}").contains("Link {"));
	assert!(format!("{unsafe_link:?}").contains("ordinary"));
}

fn opened(source: &str) -> Option<String> {
	let mut pending = kinds(source);
	while let Some(node) = pending.pop() {
		match node {
			Node::Link { opens, .. } | Node::Image { opens, .. } => return opens,
			other => pending.extend(other.children().unwrap_or_default().iter().cloned()),
		}
	}
	panic!("{source:?} holds no link");
}

#[test]
fn a_link_shows_the_place_it_opens_unless_its_label_already_says_it() {
	let host = Some(String::from("example.org"));
	// A pasted address is its own label, with or without a path or a scheme.
	assert_eq!(opened("https://example.org/a?b#c"), None);
	assert_eq!(opened("www.example.org"), None);
	assert_eq!(opened("[example.org](http://example.org/elsewhere)"), None);
	assert_eq!(opened("[`EXAMPLE.org`](https://example.org)"), None);
	assert_eq!(opened("mallory@example.org"), None);
	// Words say nothing about where a link goes, so the place is shown.
	assert_eq!(opened("[the guide](https://example.org/guide)"), host);
	assert_eq!(opened("[guide][g]\n\n[g]: https://example.org"), host);
	assert_eq!(opened("![map](https://example.org/map.png)"), host);
	assert_eq!(opened("![](https://example.org/map.png)"), None);
	// A label that names another place is shown the true one.
	for label in [
		"bank.example",
		"https://bank.example",
		"https://bank.example@example.org",
		"example.org.bank.example",
		"bank.example/example.org",
		"**bank**.example",
	] {
		assert_eq!(
			opened(&format!("[{label}](https://example.org/bank.example)")),
			host,
			"{label}"
		);
	}
	assert_eq!(opened("![bank.example](https://example.org/map.png)"), host);
	// A user name or a password before the host reads as the host to a hurried eye.
	assert_eq!(opened("https://bank.example@example.org/"), host);
	assert_eq!(opened("<https://:bank.example@example.org/>"), host);
	// A covered word is no word a reader can check.
	assert_eq!(opened("[||example.org/||bank.example](https://example.org/x)"), host);
	// A port is part of the place, and the scheme's own port is not.
	let port = Some(String::from("example.org:8443"));
	assert_eq!(opened("[example.org](https://example.org:8443/)"), port);
	assert_eq!(opened("[example.org:8080](https://example.org:8443/)"), port);
	assert_eq!(opened("[example.org:8443](https://example.org:8443/)"), None);
	assert_eq!(opened("[example.org:443](https://example.org/)"), None);
	// A mailbox is the place of a mail link, and a host does not name one.
	assert_eq!(
		opened("[alice@example.org](mailto:mallory@example.org)"),
		Some(String::from("mallory@example.org"))
	);
	assert_eq!(opened("[Alice@Example.org](mailto:alice@example.org)"), None);
	assert_eq!(
		opened("[example.org](mailto:alice@example.org)"),
		Some(String::from("alice@example.org"))
	);
	assert_eq!(
		opened("[example.org/x](mailto:example.org)"),
		Some(String::from("example.org"))
	);
	assert_eq!(
		opened("[alice@example.org](mailto:alice@example.org?Subject=hi&body=there)"),
		None
	);
	// An address is no link when the place it opens is not the place read here.
	for address in [
		// A query fills in a subject and a body. Any other field may add a
		// recipient the mailbox does not show, and so may a fragment.
		"mailto:alice@example.org?cc=mallory@example.org",
		"mailto:alice@example.org?subject=hi&%74o=mallory@example.org",
		"mailto:alice@example.org?%20cc=mallory@example.org",
		"mailto:alice@example.org?newsgroups=example",
		"mailto:alice@example.org#?cc=mallory@example.org",
		// A mail link written with a host, or with no mailbox, shows none.
		"mailto://mallory@example.org",
		"mailto://bank.example/mallory@example.org",
		"mailto:?subject=hi",
		// Without `//`, a browser reads a web address as a path on the page's own host.
		"https:example.org",
		"https:/example.org",
		"HTTP:example.org/x",
	] {
		let unlinked = kinds(&format!("[example.org]({address})"));
		assert!(!format!("{unlinked:?}").contains("Link"), "{address}");
	}
	assert_eq!(opened("[example.org](HTTPS://EXAMPLE.org/x)"), None);
	// Two scripts draw one word, so a host outside ASCII is shown encoded.
	assert_eq!(
		opened("https://b\u{0430}nk.example/"),
		Some(String::from("xn--bnk-6cd.example"))
	);
}

#[test]
fn html_is_literal_and_images_never_gain_fetch_authority() {
	let html_source = "<img src=x data-owner=\"@zoe\" onerror=alert(1)>";
	let html = Document::read(html_source);
	assert_eq!(text_in(&html.blocks), html_source);
	assert!(!html.mentions("zoe"));
	let image = kinds("![map](https://example.com/map.png)");
	assert!(matches!(
		&image[0],
		Node::Paragraph { children } if matches!(&children[0], Node::Image { destination: Some(_), .. })
	));
}

#[test]
fn references_footnotes_spoilers_and_mentions_share_the_projection() {
	let document = Document::read("[site][s] ||**secret @zoe**|| `@zoe`[^n]\n\n[s]: https://example.com\n[^n]: note");
	assert!(document.mentions("zoe"));
	assert!(format!("{:?}", document.blocks).contains("FootnoteDefinition"));
	assert!(format!("{:?}", document.blocks).contains("Spoiler"));
	assert!(format!("{:?}", document.blocks).contains("Strong"));
	assert!(!Document::read("`@zoe`").mentions("zoe"));
	assert!(!Document::read("zoe@example.com").mentions("example"));
}

#[test]
fn pathological_depth_degrades_to_exact_source() {
	let source = "> ".repeat(MAX_DEPTH + 2) + "deep";
	let document = Document::read(&source);
	assert_eq!(document.degraded, Some(Degradation::DocumentTooComplex));
	assert_eq!(document.blocks, vec![Node::Text { text: source }]);
}
