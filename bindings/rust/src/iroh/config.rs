use super::*;

impl Config {
	/// A configuration with only the mandatory posture set, every timeout left
	/// to the transport.
	pub fn new(reachability: Reachability) -> Config {
		Config {
			reachability,
			connect_timeout_ms: None,
			idle_timeout_ms: None,
			worker_threads: None,
		}
	}

	/// How long a connection may go with nothing arriving on it before it is
	/// declared dead. See the type's own documentation for why this is the knob
	/// a presence-shaped application sets.
	pub fn with_idle_timeout_ms(mut self, ms: u64) -> Config {
		self.idle_timeout_ms = Some(ms);
		self
	}

	/// How long establishing a connection may take before it is abandoned.
	pub fn with_connect_timeout_ms(mut self, ms: u64) -> Config {
		self.connect_timeout_ms = Some(ms);
		self
	}

	/// Worker threads for this endpoint's runtime.
	pub fn with_worker_threads(mut self, threads: u32) -> Config {
		self.worker_threads = Some(threads);
		self
	}
}
