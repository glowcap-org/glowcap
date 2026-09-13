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
