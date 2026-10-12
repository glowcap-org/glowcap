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

#[derive(Clone)]
enum PreviewError {
	Failure(FailureCode),
	Admission(rooms_application::admission::Refusal),
}

pub(super) struct Preview {
	admission: Rc<super::admission::Admission>,
	tls: TlsConnector,
	capacity: Arc<Semaphore>,
	metadata: Rc<RefCell<cache::Pool<Result<Metadata, PreviewError>>>>,
	images: Rc<RefCell<cache::Pool<Result<Image, PreviewError>>>>,
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
	pub async fn open(admission: Rc<super::admission::Admission>) -> Result<Self, String> {
		Ok(Self {
			admission,
			tls: TlsConnector::from(Arc::new(rooms_platform::tls::system_config().await?)),
			capacity: Arc::new(Semaphore::new(16)),
			metadata: cache::Pool::new(128, 2 * 1024 * 1024, metadata_weight, result_ttl),
			images: cache::Pool::new(32, 32 * 1024 * 1024, image_weight, result_ttl),
		})
	}

	pub async fn metadata(&self, url: &str, refresh: bool, address: Option<std::net::IpAddr>) -> Reply {
		let Some(url) = normalize_url(url) else {
			return failure_for(FailureCode::LinkPreviewInvalidUrl);
		};
		if refresh {
			cache::refresh(&self.metadata, &url);
		}
		let admission = self.admission.clone();
		let loading = load_metadata(self, url.clone());
		let result = cache::coalesce(&self.metadata, url, async move {
			admission
				.start(rooms_application::admission::Class::Preview, address)
				.map_err(PreviewError::Admission)?;
			loading.await.map_err(PreviewError::Failure)
		})
		.await;
		match result {
			Ok(metadata) => json(StatusCode::OK, &MetadataReply::Ready { ok: true, metadata }),
			Err(error) => preview_failure(error),
		}
	}

	pub async fn image(&self, url: &str, address: Option<std::net::IpAddr>) -> Reply {
		let Some(url) = normalize_url(url) else {
			return failure_for(FailureCode::LinkPreviewInvalidUrl);
		};
		let admission = self.admission.clone();
		let loading = load_image(self, url.clone());
		match cache::coalesce(&self.images, url, async move {
			admission
				.start(rooms_application::admission::Class::Preview, address)
				.map_err(PreviewError::Admission)?;
			loading.await.map_err(PreviewError::Failure)
		})
		.await
		{
			Ok(image) => hyper::Response::builder()
				.status(StatusCode::OK)
				.header("content-type", image.content_type)
				.header("cache-control", "private, max-age=3600")
				.header("x-content-type-options", "nosniff")
				.body(http_body_util::Full::new(image.body))
				.unwrap_or_else(|_| failure_for(FailureCode::LinkPreviewContentUnsupported)),
			Err(error) => preview_failure(error),
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

fn preview_failure(error: PreviewError) -> Reply {
	match error {
		PreviewError::Failure(code) => failure_for(code),
		PreviewError::Admission(refusal) => {
			let carrier = super::admission::reply(refusal);
			let code = match refusal {
				rooms_application::admission::Refusal::Throttled { .. } => FailureCode::RateLimited,
				rooms_application::admission::Refusal::Capacity => FailureCode::AdmissionBusy,
				rooms_application::admission::Refusal::TooLarge { .. } => FailureCode::RequestTooLarge,
			};
			let mut reply = failure(carrier.status(), code);
			if let Some(retry) = carrier.headers().get("retry-after") {
				reply.headers_mut().insert("retry-after", retry.clone());
			}
			reply
		}
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

fn result_ttl<T>(result: &Result<T, PreviewError>) -> Duration {
	match result {
		Ok(_) => Duration::from_secs(60 * 60),
		Err(
			PreviewError::Admission(_)
			| PreviewError::Failure(FailureCode::LinkPreviewBusy | FailureCode::LinkPreviewFailed),
		) => Duration::ZERO,
		Err(PreviewError::Failure(code)) if code.definition().retry == rooms_application::failure::Retry::Soon => {
			Duration::from_secs(30)
		}
		Err(_) => Duration::from_secs(5 * 60),
	}
}

fn metadata_weight(result: &Result<Metadata, PreviewError>) -> usize {
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

fn image_weight(result: &Result<Image, PreviewError>) -> usize {
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
