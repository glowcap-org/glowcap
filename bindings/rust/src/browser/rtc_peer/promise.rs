//! A revocable observation of a browser promise. WebRTC may leave operations
//! unsettled when its connection closes. Race with a private cancellation
//! promise so JsFuture's Rust callbacks always settle and release their state.
//! The operation's original promise retains only JavaScript race reactions.
use js_sys::{Array, Function, Promise, futures::JsFuture};
use wasm_bindgen::JsValue;

pub(super) struct Observation {
	future: JsFuture,
	cancel: Cancellation,
}

#[derive(Clone)]
pub(super) struct Cancellation(Function);
impl Cancellation {
	pub(super) fn cancel(&self) {
		// This is the intrinsic resolver created by Promise::new, never a
		// supplied callback. Resolving with undefined cannot throw or recurse.
		self.0
			.call1(&JsValue::UNDEFINED, &JsValue::UNDEFINED)
			.expect("intrinsic promise resolver");
	}
}

impl Observation {
	pub(super) fn new(promise: Promise) -> Self {
		let mut cancel = None;
		let cancelled = Promise::new(&mut |resolve, _| cancel = Some(Cancellation(resolve)));
		let choices = Array::new();
		choices.push(&promise);
		choices.push(&cancelled);
		Self {
			future: JsFuture::from(Promise::race(&choices)),
			cancel: cancel.expect("synchronous promise executor"),
		}
	}
	pub(super) fn cancellation(&self) -> Cancellation {
		self.cancel.clone()
	}
	pub(super) async fn finish(&mut self) -> Result<JsValue, JsValue> {
		(&mut self.future).await
	}
}

impl Drop for Observation {
	fn drop(&mut self) {
		self.cancel.cancel();
	}
}
