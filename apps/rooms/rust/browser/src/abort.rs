//! An owned browser AbortSignal subscription. Dropping the observer removes its
//! event handler. Cancellation is consumed by the Rust effect that owns the work.
use tokio::sync::watch;
use wasm_bindgen::{JsCast, closure::Closure};

pub(crate) struct Abort {
	signal: Option<web_sys::AbortSignal>,
	callback: Closure<dyn FnMut()>,
	stopped: watch::Receiver<bool>,
}
impl Abort {
	pub fn new(signal: Option<web_sys::AbortSignal>) -> Result<Self, rooms_runtime::Error> {
		let (stop, stopped) = watch::channel(signal.as_ref().is_some_and(web_sys::AbortSignal::aborted));
		let callback = Closure::new(move || {
			stop.send_replace(true);
		});
		if let Some(signal) = &signal {
			signal
				.add_event_listener_with_callback("abort", callback.as_ref().unchecked_ref())
				.map_err(|_| {
					rooms_runtime::Error::platform_message("Rooms cancellation handler could not be installed")
				})?;
		}
		Ok(Self {
			signal,
			callback,
			stopped,
		})
	}
	pub async fn cancelled(&mut self) {
		if self.signal.is_none() {
			return std::future::pending().await;
		}
		while !*self.stopped.borrow() {
			if self.stopped.changed().await.is_err() {
				return;
			}
		}
	}
}
/// Completes once a stop flag is raised. Its writers only ever send `true`
/// into a flag that began `false`, so an unseen change always means stopped.
pub(crate) async fn stopped(stop: &mut watch::Receiver<bool>) {
	if !*stop.borrow() {
		let _ = stop.changed().await;
	}
}
impl Drop for Abort {
	fn drop(&mut self) {
		if let Some(signal) = &self.signal {
			let _ = signal.remove_event_listener_with_callback("abort", self.callback.as_ref().unchecked_ref());
		}
	}
}
