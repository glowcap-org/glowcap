use rooms_application::open_graph::{Metadata, OEmbedObservation};
use serde::Deserialize;

pub(super) const BODY_LIMIT: usize = 64 * 1024;

/// Known providers take the bounded metadata path before Rooms considers a
/// full page. Each endpoint is the provider's documented oEmbed service.
/// Arbitrary pages never choose a second host.
///
/// Endpoint references:
/// - <https://developers.google.com/youtube/v3/guides/implementation/oembed>
/// - <https://www.reddit.com/dev/api/#GET_api_oembed>
/// - <https://developer.vimeo.com/api/oembed/videos>
pub(super) fn endpoint(target: &str) -> Option<String> {
	let target_url = url::Url::parse(target).ok()?;
	let host = target_url.host_str()?;
	let provider = if domain(host, "youtube.com") || host.eq_ignore_ascii_case("youtu.be") {
		Provider::YouTube
	} else if domain(host, "reddit.com") {
		Provider::Reddit
	} else if domain(host, "vimeo.com") {
		Provider::Vimeo
	} else {
		return None;
	};
	#[expect(clippy::expect_used, reason = "a literal `provider_endpoints_parse` parses")]
	let mut endpoint = url::Url::parse(provider.endpoint()).expect("fixed oEmbed endpoint");
	{
		let mut query = endpoint.query_pairs_mut();
		query.append_pair("url", target);
		if provider == Provider::YouTube {
			query.append_pair("format", "json");
		}
	}
	Some(endpoint.into())
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum Provider {
	YouTube,
	Reddit,
	Vimeo,
}

impl Provider {
	fn endpoint(self) -> &'static str {
		match self {
			Self::YouTube => "https://www.youtube.com/oembed",
			Self::Reddit => "https://www.reddit.com/oembed",
			Self::Vimeo => "https://vimeo.com/api/oembed.json",
		}
	}
}

fn domain(host: &str, base: &str) -> bool {
	host.eq_ignore_ascii_case(base)
		|| host
			.get(..host.len().saturating_sub(base.len()))
			.is_some_and(|prefix| prefix.ends_with('.') && host[host.len() - base.len()..].eq_ignore_ascii_case(base))
}

#[derive(Deserialize)]
struct Response {
	title: Option<String>,
	provider_name: Option<String>,
	#[serde(rename = "type")]
	object_type: Option<String>,
	thumbnail_url: Option<String>,
	thumbnail_width: Option<u32>,
	thumbnail_height: Option<u32>,
}

pub(super) fn metadata(target: &str, body: &[u8]) -> Option<Metadata> {
	let response: Response = serde_json::from_slice(body).ok()?;
	Metadata::from_oembed(&OEmbedObservation {
		requested_url: target,
		title: response.title.as_deref(),
		provider_name: response.provider_name.as_deref(),
		object_type: response.object_type.as_deref(),
		thumbnail_url: response.thumbnail_url.as_deref(),
		thumbnail_width: response.thumbnail_width,
		thumbnail_height: response.thumbnail_height,
	})
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn endpoints_are_provider_owned_and_preserve_the_exact_target() {
		for (target, provider) in [
			("https://youtu.be/video?si=share", "www.youtube.com"),
			("https://www.youtube.com/watch?v=video", "www.youtube.com"),
			("https://old.reddit.com/r/rooms/comments/example", "www.reddit.com"),
			("https://vimeo.com/123", "vimeo.com"),
		] {
			let endpoint = url::Url::parse(&endpoint(target).unwrap()).unwrap();
			assert_eq!(endpoint.host_str(), Some(provider));
			assert_eq!(endpoint.query_pairs().find(|(key, _)| key == "url").unwrap().1, target);
		}
		assert!(endpoint("https://youtube.com.evil.example/watch?v=x").is_none());
	}

	#[test]
	fn provider_endpoints_parse() {
		for provider in [Provider::YouTube, Provider::Reddit, Provider::Vimeo] {
			assert!(url::Url::parse(provider.endpoint()).is_ok());
		}
	}

	#[test]
	fn response_admits_display_fields_but_not_embed_html() {
		let found = metadata(
			"https://youtu.be/video",
			br#"{"type":"video","provider_name":"YouTube","title":"A video","thumbnail_url":"https://i.example/video.jpg","thumbnail_width":480,"thumbnail_height":360,"html":"<script>bad()</script>"}"#,
		)
		.unwrap();
		assert_eq!(found.title.as_deref(), Some("A video"));
		assert_eq!(found.site_name.as_deref(), Some("YouTube"));
		assert_eq!(found.images[0].url, "https://i.example/video.jpg");
	}
}
