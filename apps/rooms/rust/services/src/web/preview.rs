//! Same-origin, privacy-preserving Open Graph and image proxy.
mod cache;
mod fetch;
mod oembed;
mod parse;

use super::http::{Reply, response};
use bytes::Bytes;
use fetch::{Error, Kind};
use hyper::StatusCode;
use rooms_application::failure::FailureCode;
use rooms_application::open_graph::{Metadata, normalize_url};
use serde::Serialize;
use std::{cell::RefCell, rc::Rc, sync::Arc, time::Duration};
use tokio::sync::Semaphore;
use tokio_rustls::TlsConnector;

const HTML_LIMIT: usize = 512 * 1024;
const IMAGE_LIMIT: usize = 4 * 1024 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const OEMBED_TIMEOUT: Duration = Duration::from_secs(4);

pub(super) struct Preview {
	tls: TlsConnector,
	capacity: Arc<Semaphore>,
	metadata: Rc<RefCell<cache::Pool<Result<Metadata, FailureCode>>>>,
	images: Rc<RefCell<cache::Pool<Result<Image, FailureCode>>>>,
}

#[derive(Clone)]
struct Image {
	content_type: String,
	body: Bytes,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Failure {
	code: &'static str,
	summary: &'static str,
	action: Option<&'static str>,
	retry: &'static str,
}

#[derive(Serialize)]
#[serde(untagged)]
enum MetadataReply {
	Ready {
		ok: bool,
		metadata: rooms_application::open_graph::Metadata,
	},
	Failed {
		ok: bool,
		failure: Failure,
	},
}

impl Preview {
	pub async fn open() -> Result<Self, String> {
		Ok(Self {
			tls: TlsConnector::from(Arc::new(rooms_platform::tls::system_config().await?)),
			capacity: Arc::new(Semaphore::new(16)),
			metadata: cache::Pool::new(128, 2 * 1024 * 1024, metadata_weight, result_ttl),
			images: cache::Pool::new(32, 32 * 1024 * 1024, image_weight, result_ttl),
		})
	}

	pub async fn metadata(&self, url: &str, refresh: bool) -> Reply {
		let Some(url) = normalize_url(url) else {
			return failure_for(FailureCode::LinkPreviewInvalidUrl);
		};
		if refresh {
			cache::refresh(&self.metadata, &url);
		}
		let result = cache::coalesce(&self.metadata, url.clone(), load_metadata(self, url)).await;
		match result {
			Ok(metadata) => json(StatusCode::OK, &MetadataReply::Ready { ok: true, metadata }),
			Err(code) => failure_for(code),
		}
	}

	pub async fn image(&self, url: &str) -> Reply {
		let Some(url) = normalize_url(url) else {
			return failure_for(FailureCode::LinkPreviewInvalidUrl);
		};
		match cache::coalesce(&self.images, url.clone(), load_image(self, url)).await {
			Ok(image) => hyper::Response::builder()
				.status(StatusCode::OK)
				.header("content-type", image.content_type)
				.header("cache-control", "private, max-age=3600")
				.header("x-content-type-options", "nosniff")
				.body(http_body_util::Full::new(image.body))
				.expect("validated preview image response"),
			Err(code) => failure_for(code),
		}
	}
}

fn load_metadata(
	preview: &Preview,
	url: String,
) -> impl core::future::Future<Output = Result<Metadata, FailureCode>> + 'static {
	let tls = preview.tls.clone();
	let capacity = preview.capacity.clone();
	async move {
		let _slot = capacity.try_acquire_owned().map_err(|_| FailureCode::LinkPreviewBusy)?;
		tokio::time::timeout(REQUEST_TIMEOUT, load_metadata_effect(&tls, &url))
			.await
			.map_err(|_| FailureCode::LinkPreviewTimedOut)?
	}
}

async fn load_metadata_effect(tls: &TlsConnector, url: &str) -> Result<Metadata, FailureCode> {
	if let Some(endpoint) = oembed::endpoint(url) {
		let fetched = tokio::time::timeout(
			OEMBED_TIMEOUT,
			fetch::get(tls, &endpoint, oembed::BODY_LIMIT, Kind::Json),
		)
		.await;
		if let Ok(Ok(fetched)) = fetched
			&& let Some(metadata) = oembed::metadata(url, &fetched.body)
		{
			return Ok(metadata);
		}
	}
	let fetched = fetch::get(tls, url, HTML_LIMIT, Kind::Html)
		.await
		.map_err(failure_code)?;
	parse::metadata(url, &fetched.final_url, &fetched.content_type, &fetched.body)
		.ok_or(FailureCode::LinkPreviewMetadataMissing)
}

fn load_image(
	preview: &Preview,
	url: String,
) -> impl core::future::Future<Output = Result<Image, FailureCode>> + 'static {
	let tls = preview.tls.clone();
	let capacity = preview.capacity.clone();
	async move {
		let _slot = capacity.try_acquire_owned().map_err(|_| FailureCode::LinkPreviewBusy)?;
		let fetched = tokio::time::timeout(REQUEST_TIMEOUT, fetch::get(&tls, &url, IMAGE_LIMIT, Kind::Image))
			.await
			.map_err(|_| FailureCode::LinkPreviewTimedOut)?
			.map_err(failure_code)?;
		Ok(Image {
			content_type: fetched.content_type,
			body: fetched.body,
		})
	}
}

fn failure_code(error: Error) -> FailureCode {
	match error {
		Error::InvalidUrl => FailureCode::LinkPreviewInvalidUrl,
		Error::AddressBlocked => FailureCode::LinkPreviewAddressBlocked,
		Error::Dns => FailureCode::LinkPreviewDnsFailed,
		Error::Connect | Error::Tls | Error::Http => FailureCode::LinkPreviewUnreachable,
		Error::Status => FailureCode::LinkPreviewHttpRefused,
		Error::Redirect => FailureCode::LinkPreviewRedirectRefused,
		Error::Content => FailureCode::LinkPreviewContentUnsupported,
		Error::TooLarge => FailureCode::LinkPreviewTooLarge,
	}
}

fn failure_for(code: FailureCode) -> Reply {
	let status = match code {
		FailureCode::LinkPreviewInvalidUrl => StatusCode::BAD_REQUEST,
		FailureCode::LinkPreviewAddressBlocked => StatusCode::FORBIDDEN,
		FailureCode::LinkPreviewTimedOut => StatusCode::GATEWAY_TIMEOUT,
		FailureCode::LinkPreviewContentUnsupported => StatusCode::UNSUPPORTED_MEDIA_TYPE,
		FailureCode::LinkPreviewTooLarge => StatusCode::PAYLOAD_TOO_LARGE,
		FailureCode::LinkPreviewMetadataMissing => StatusCode::UNPROCESSABLE_ENTITY,
		FailureCode::LinkPreviewBusy | FailureCode::LinkPreviewFailed => StatusCode::SERVICE_UNAVAILABLE,
		_ => StatusCode::BAD_GATEWAY,
	};
	failure(status, code)
}

fn result_ttl<T>(result: &Result<T, FailureCode>) -> Duration {
	match result {
		Ok(_) => Duration::from_secs(60 * 60),
		Err(FailureCode::LinkPreviewBusy | FailureCode::LinkPreviewFailed) => Duration::ZERO,
		Err(code) if code.definition().retry == rooms_application::failure::Retry::Soon => Duration::from_secs(30),
		Err(_) => Duration::from_secs(5 * 60),
	}
}

fn metadata_weight(result: &Result<Metadata, FailureCode>) -> usize {
	result.as_ref().map_or(64, |metadata| {
		metadata.requested_url.len()
			+ metadata.url.len()
			+ metadata.title.as_ref().map_or(0, String::len)
			+ metadata.description.as_ref().map_or(0, String::len)
			+ metadata.site_name.as_ref().map_or(0, String::len)
			+ metadata.object_type.as_ref().map_or(0, String::len)
			+ metadata
				.images
				.iter()
				.map(|image| image.url.len() + image.alt.as_ref().map_or(0, String::len))
				.sum::<usize>()
	})
}

fn image_weight(result: &Result<Image, FailureCode>) -> usize {
	result
		.as_ref()
		.map_or(64, |image| image.content_type.len() + image.body.len())
}

fn failure(status: StatusCode, code: FailureCode) -> Reply {
	let definition = code.definition();
	json(
		status,
		&MetadataReply::Failed {
			ok: false,
			failure: Failure {
				code: code.wire(),
				summary: definition.summary,
				action: definition.action,
				retry: definition.retry.wire(),
			},
		},
	)
}

fn json(status: StatusCode, value: &impl Serialize) -> Reply {
	match serde_json::to_vec(value) {
		Ok(body) => response(status, "application/json; charset=utf-8", Bytes::from(body)),
		Err(_) => response(
			StatusCode::INTERNAL_SERVER_ERROR,
			"application/json; charset=utf-8",
			Bytes::from_static(br#"{"ok":false,"failure":{"code":"link-preview-failed","summary":"Rooms could not build that link preview.","action":"Retry once. The link itself is still available.","retry":"soon"}}"#),
		),
	}
}
