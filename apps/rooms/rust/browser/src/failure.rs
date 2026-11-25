//! Project typed runtime failures once at the JavaScript boundary.
use rooms_application::{
	admission::RetryAdvice,
	failure::{Failure, FailureCode},
};
use rooms_runtime::Error;
use std::borrow::Cow;
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
extern "C" {
	#[wasm_bindgen(extends = js_sys::Error)]
	type BrowserError;
	#[wasm_bindgen(method, setter, structural)]
	fn set_status(this: &BrowserError, status: Option<i32>);
	#[wasm_bindgen(method, setter, structural)]
	fn set_reason(this: &BrowserError, reason: &str);
	#[wasm_bindgen(method, setter, structural)]
	fn set_code(this: &BrowserError, code: Option<&str>);
	#[wasm_bindgen(method, setter, structural)]
	fn set_detail(this: &BrowserError, detail: &str);
	#[wasm_bindgen(method, setter, structural, js_name = retryAfterMs)]
	fn set_retry_after_ms(this: &BrowserError, delay: Option<f64>);
	#[wasm_bindgen(method, setter, structural)]
	fn set_scope(this: &BrowserError, scope: Option<&str>);
	#[wasm_bindgen(method, setter, structural)]
	fn set_owner(this: &BrowserError, owner: Option<&str>);
}

pub(crate) struct Projection<'a> {
	pub status: Option<i32>,
	pub reason: Cow<'a, str>,
	pub code: Option<FailureCode>,
	pub detail: Cow<'a, str>,
	pub advice: Option<RetryAdvice>,
}
impl<'a> Projection<'a> {
	fn binding(error: &'a glowcap::Error) -> Self {
		let reason = error.message().unwrap_or("");
		Self::new(
			Some(error.code()),
			Cow::Borrowed(reason),
			rooms_glowcap::client::binding_failure(error),
		)
	}
	fn new(status: Option<i32>, reason: Cow<'a, str>, failure: Option<Failure<'_>>) -> Self {
		Self {
			status,
			detail: failure.map_or_else(|| reason.clone(), |failure| Cow::Owned(failure.detail.into())),
			code: failure.map(|failure| failure.code),
			advice: failure.and_then(Failure::retry_advice),
			reason,
		}
	}
	/// A failure with no binding status. Its code is the one its error holds
	/// as a value, never one read from the rendered text.
	fn local(error: &impl std::fmt::Display, failure: Option<Failure<'_>>) -> Self {
		Self::new(None, Cow::Owned(error.to_string()), failure)
	}
	pub fn value(&self) -> serde_json::Value {
		serde_json::json!({
			"status": self.status, "reason": self.reason, "code": self.code.map(FailureCode::wire),
			"detail": self.detail, "retryAfterMs": self.advice.map(|advice| advice.retry_ms),
			"scope": self.advice.map(|advice| advice.class.name()),
			"owner": self.advice.and_then(|advice| advice.owner.map(|owner| owner.name())),
		})
	}
}

pub(crate) fn project(error: &Error) -> Projection<'_> {
	match error {
		Error::Cleanup { primary, .. } => project(primary),
		Error::Context { source, .. } => project(source),
		Error::Admission { refusal, owner } => Projection {
			status: None,
			reason: Cow::Owned(error.to_string()),
			detail: Cow::Owned(refusal.detail(*owner)),
			code: Some(refusal.code()),
			advice: refusal.retry_advice(*owner),
		},
		Error::Captp(error) => Projection::binding(error),
		Error::Peer(error) => match error.as_ref() {
			rooms_glowcap::client::Error::Binding(error) | rooms_glowcap::client::Error::Unsent(error) => {
				Projection::binding(error)
			}
			peer => Projection::local(peer, peer.failure()),
		},
		Error::Coded { code, detail } => {
			Projection::new(None, Cow::Borrowed(detail), Some(Failure { code: *code, detail }))
		}
		Error::Storage(_)
		| Error::Platform(_)
		| Error::Refused(_)
		| Error::Invalid(_)
		| Error::Busy(_)
		| Error::Exhausted(_)
		| Error::Stale(_)
		| Error::Closed(_)
		| Error::Uncertain(_) => Projection::local(error, None),
	}
}

pub(crate) fn js_error(error: &Error) -> JsValue {
	let projection = project(error);
	let result: BrowserError = js_sys::Error::new(&error.to_string()).unchecked_into();
	result.set_status(projection.status);
	result.set_reason(&projection.reason);
	result.set_code(projection.code.map(FailureCode::wire));
	result.set_detail(&projection.detail);
	result.set_retry_after_ms(projection.advice.map(|advice| advice.retry_ms as f64));
	result.set_scope(projection.advice.map(|advice| advice.class.name()));
	result.set_owner(
		projection
			.advice
			.and_then(|advice| advice.owner.map(|owner| owner.name())),
	);
	result.into()
}
