//! Browser monotonic time, local task custody, and cryptographic entropy.
use rooms_runtime::{
	clock::Clock,
	entropy::{Entropy, EntropyUnavailable},
};
use std::{future::Future, io, time::Duration};
use wasm_bindgen::JsCast;

#[derive(Clone)]
pub struct Platform {
	performance: web_sys::Performance,
	crypto: web_sys::Crypto,
}
impl Platform {
	/// Resolve the browser's APIs once, usable in a Window or Worker realm.
	pub fn new() -> io::Result<Self> {
		fn global<T: JsCast>(name: &str) -> io::Result<T> {
			js_sys::Reflect::get(&js_sys::global(), &name.into())
				.ok()
				.and_then(|value| value.dyn_into().ok())
				.ok_or_else(|| {
					io::Error::new(
						io::ErrorKind::Unsupported,
						"Rooms requires browser time and cryptographic entropy",
					)
				})
		}
		Ok(Self {
			performance: global("performance")?,
			crypto: global("crypto")?,
		})
	}
	fn fill_random(&self, bytes: &mut [u8]) -> Result<(), EntropyUnavailable> {
		for chunk in bytes.chunks_mut(65_536) {
			self.crypto
				.get_random_values_with_u8_array(chunk)
				.map_err(|_| EntropyUnavailable)?;
		}
		Ok(())
	}
}
impl Clock for Platform {
	type Instant = Duration;
	fn now(&self) -> Duration {
		Duration::from_secs_f64(self.performance.now() / 1000.0)
	}
	async fn sleep_until(&self, at: Duration) {
		while let Some(remaining) = at.checked_sub(self.now()).filter(|duration| !duration.is_zero()) {
			// Browser timers have a finite integer range. Recheck the monotonic
			// deadline after each wake, including early timer rounding.
			let milliseconds = remaining.as_millis().clamp(1, i32::MAX as u128) as u32;
			gloo_timers::future::TimeoutFuture::new(milliseconds).await;
		}
	}
}
impl Entropy for Platform {
	fn fill(&mut self, bytes: &mut [u8]) -> Result<(), EntropyUnavailable> {
		self.fill_random(bytes)
	}
}
impl rooms_glowcap::client::direct::publisher::Entropy for Platform {
	fn inbox_entropy(&self) -> Result<[u8; 32], rooms_glowcap::client::Error> {
		let mut bytes = [0; 32];
		self.fill_random(&mut bytes)
			.map_err(|_| rooms_application::direct::publication::Error::Entropy)?;
		Ok(bytes)
	}
}
impl rooms_glowcap::client::Entropy for Platform {
	fn invitation_receipt(
		&self,
	) -> Result<rooms_application::room::invitation::Receipt, rooms_application::room::invitation::Error> {
		let mut bytes = [0; 16];
		self.fill_random(&mut bytes)
			.map_err(|_| rooms_application::room::invitation::Error::Entropy)?;
		Ok(rooms_application::room::invitation::Receipt::from_entropy(bytes))
	}
}

pub struct Task(tokio::task::JoinHandle<()>);
impl Drop for Task {
	fn drop(&mut self) {
		self.0.abort();
	}
}
impl rooms_glowcap::client::Tasks for Platform {
	type Task = Task;
	fn spawn(&self, work: impl Future<Output = ()> + 'static) -> Task {
		Task(tokio::task::spawn_local(work))
	}
}
impl rooms_glowcap::client::Deadline for Platform {
	fn monotonic_millis(&self) -> u64 {
		u64::try_from(self.now().as_millis()).unwrap_or(u64::MAX)
	}
	async fn within<T>(&self, milliseconds: u64, work: impl Future<Output = T>) -> Option<T> {
		tokio::select! {
			biased;
			result = work => Some(result),
			() = self.sleep_until(self.now() + Duration::from_millis(milliseconds)) => None,
		}
	}
}

impl rooms_runtime::wall_clock::WallClock for Platform {
	fn unix_millis(&self) -> Result<u64, rooms_runtime::wall_clock::Error> {
		use rooms_runtime::wall_clock::Error;
		let milliseconds = js_sys::Date::now();
		if !milliseconds.is_finite() || milliseconds > js_sys::Number::MAX_SAFE_INTEGER {
			return Err(Error::OutOfRange);
		}
		if milliseconds < 0.0 {
			return Err(Error::BeforeEpoch);
		}
		Ok(milliseconds as u64)
	}
}
