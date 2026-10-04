use super::*;
use alloc::vec;

fn property(key: &str, content: &str) -> Property {
	Property::new(key, content).unwrap()
}

#[test]
fn candidates_follow_markdown_authority_and_normalize_identity() {
	let source = concat!(
		"[one](HTTPS://Example.COM:443/page#first) ",
		"<https://example.com/page#second> ",
		"`https://ignored.example` ",
		"![image](https://image.example/a.png) ",
		"[mail](mailto:a@example.com) ",
		"<img data-url=\"https://html.example\">"
	);
	assert_eq!(
		Document::read(source).preview_targets(),
		vec![Target {
			url: "https://example.com/page".into()
		}]
	);
}

#[test]
fn metadata_applies_precedence_relative_urls_and_structured_images() {
	let properties = vec![
		property("twitter:title", "fallback"),
		property("og:title", "  The   page  "),
		property("og:description", "A useful page"),
		property("og:url", "/canonical#tracking"),
		property("og:image", "/first.jpg"),
		property("og:image:width", "1200"),
		property("og:image:height", "630"),
		property("og:image:alt", "A diagram"),
		property("og:image", "https://cdn.example/second.jpg"),
	];
	let metadata = Metadata::from_observation(&Observation {
		requested_url: "https://example.com/start#fragment",
		final_url: "https://example.com/final/path",
		canonical_url: None,
		html_title: Some("HTML title"),
		properties: &properties,
	})
	.unwrap();
	assert_eq!(metadata.requested_url, "https://example.com/start");
	assert_eq!(metadata.url, "https://example.com/canonical");
	assert_eq!(metadata.title.as_deref(), Some("The page"));
	assert_eq!(metadata.images.len(), 2);
	assert_eq!(metadata.images[0].url, "https://example.com/first.jpg");
	assert_eq!(metadata.images[0].width, Some(1200));
	assert_eq!(metadata.images[0].alt.as_deref(), Some("A diagram"));
	let encoded = serde_json::to_string(&metadata).unwrap();
	assert_eq!(Metadata::decode(&encoded), Some(metadata));
}

#[test]
fn oembed_admission_ignores_executable_html_and_bounds_shared_metadata() {
	let metadata = Metadata::from_oembed(&OEmbedObservation {
		requested_url: "https://youtu.be/example#tracking",
		title: Some("  A useful   video "),
		provider_name: Some("YouTube"),
		object_type: Some("video"),
		thumbnail_url: Some("https://images.example/cover.jpg"),
		thumbnail_width: Some(480),
		thumbnail_height: Some(360),
	})
	.unwrap();
	assert_eq!(metadata.requested_url, "https://youtu.be/example");
	assert_eq!(metadata.url, metadata.requested_url);
	assert_eq!(metadata.title.as_deref(), Some("A useful video"));
	assert_eq!(metadata.site_name.as_deref(), Some("YouTube"));
	assert_eq!(metadata.object_type.as_deref(), Some("video"));
	assert_eq!(metadata.images[0].width, Some(480));
	assert!(
		Metadata::from_oembed(&OEmbedObservation {
			requested_url: "https://example.com/",
			title: Some("Safe title"),
			provider_name: None,
			object_type: Some("executable"),
			thumbnail_url: None,
			thumbnail_width: None,
			thumbnail_height: None,
		})
		.is_none()
	);
}

#[test]
fn metadata_decode_holds_the_core_bounds_at_adapter_boundaries() {
	let valid =
		r#"{"requestedUrl":"https://example.com/","url":"https://example.com/page","title":"Page","images":[]}"#;
	assert!(Metadata::decode(valid).is_some());
	for invalid in [
		r#"{"requestedUrl":"https://example.com/","url":"https://example.com/","images":[]}"#,
		r#"{"requestedUrl":"https://EXAMPLE.com/","url":"https://example.com/","images":[]}"#,
		r#"{"requestedUrl":"https://example.com/","url":"javascript:alert(1)","images":[]}"#,
		r#"{"requestedUrl":"https://example.com/","url":"https://example.com/","images":[],"extra":true}"#,
		r#"{"requestedUrl":"https://example.com/","url":"https://example.com/","title":"  spaced  ","images":[]}"#,
	] {
		assert!(Metadata::decode(invalid).is_none(), "{invalid}");
	}
}

#[test]
fn empty_observations_do_not_make_cards_and_long_titles_are_bounded() {
	assert!(
		Metadata::from_observation(&Observation {
			requested_url: "https://example.com",
			final_url: "https://example.com",
			canonical_url: None,
			html_title: None,
			properties: &[],
		})
		.is_none()
	);
	let long = vec!["word"; 200].join(" ");
	let properties = vec![property("og:title", &long)];
	let metadata = Metadata::from_observation(&Observation {
		requested_url: "https://example.com",
		final_url: "https://example.com",
		canonical_url: None,
		html_title: None,
		properties: &properties,
	})
	.unwrap();
	assert!(metadata.title.unwrap().len() <= metadata::MAX_TITLE_BYTES);
	assert!(Property::new("og:title", &"x".repeat(metadata::MAX_PROPERTY_CONTENT_BYTES + 1)).is_none());
}

#[test]
fn preview_urls_refuse_credentials_and_active_schemes() {
	assert_eq!(
		normalize_url("https://example.com:443/a#b").as_deref(),
		Some("https://example.com/a")
	);
	assert!(normalize_url("https://user:secret@example.com/").is_none());
	assert!(normalize_url("javascript:alert(1)").is_none());
}

#[test]
fn selection_is_a_validated_authored_subset_with_stable_wire_identity() {
	let text = "https://first.example and https://second.example";
	let selection = Selection::new(text, ["https://second.example/"]).unwrap();
	assert_eq!(selection.urls(), &["https://second.example/"]);
	assert_eq!(Selection::decode(text, &selection.encode()).unwrap(), selection);
	assert!(Selection::new(text, ["https://other.example/"]).is_err());
	assert!(Selection::new(text, ["https://FIRST.example/"]).is_err());
	assert!(Selection::new(text, ["https://first.example/", "https://first.example/"]).is_err());
}
