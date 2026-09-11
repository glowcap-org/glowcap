//! Native scheduling for portable Rooms capability clients.
#[derive(Clone, Copy, Default)]
pub struct Deadline;
impl rooms_runtime::clock::Clock for Deadline {
	type Instant = tokio::time::Instant;
	fn now(&self) -> Self::Instant {
		tokio::time::Instant::now()
	}
	async fn sleep_until(&self, at: Self::Instant) {
		tokio::time::sleep_until(at).await
	}
}
impl rooms_glowcap::client::Entropy for Deadline {
	fn invitation_receipt(
		&self,
	) -> Result<rooms_application::room::invitation::Receipt, rooms_application::room::invitation::Error> {
		let mut bytes = [0; 16];
		getrandom::fill(&mut bytes).map_err(|_| rooms_application::room::invitation::Error::Entropy)?;
		Ok(rooms_application::room::invitation::Receipt::from_entropy(bytes))
	}
}
pub struct Task(tokio::task::JoinHandle<()>);
impl Drop for Task {
	fn drop(&mut self) {
		self.0.abort();
	}
}
impl rooms_glowcap::client::Tasks for Deadline {
	type Task = Task;
	fn spawn(&self, work: impl core::future::Future<Output = ()> + 'static) -> Task {
		Task(tokio::task::spawn_local(work))
	}
}
impl rooms_glowcap::client::Deadline for Deadline {
	async fn within<T>(&self, milliseconds: u64, work: impl core::future::Future<Output = T>) -> Option<T> {
		tokio::time::timeout(core::time::Duration::from_millis(milliseconds), work)
			.await
			.ok()
	}
}

#[cfg(test)]
mod membership_tests;
#[cfg(test)]
mod stewardship_tests;
#[cfg(test)]
mod tests;

#[cfg(test)]
mod bridge_tests;
#[cfg(test)]
mod conversation_tests;
#[cfg(test)]
mod directory_tests;
#[cfg(test)]
mod invitation_tests;
#[cfg(test)]
mod registration_tests;

#[cfg(test)]
mod introduction_tests;

#[cfg(test)]
mod signaling_tests;

#[cfg(test)]
mod direct_tests;

#[cfg(test)]
mod source_tests;

impl rooms_glowcap::client::direct::publisher::Entropy for Deadline {
	fn inbox_entropy(&self) -> Result<[u8; 32], rooms_glowcap::client::Error> {
		let mut bytes = [0; 32];
		getrandom::fill(&mut bytes).map_err(|_| rooms_application::direct::publication::Error::Entropy)?;
		Ok(bytes)
	}
}

#[cfg(test)]
mod publisher_tests;

#[cfg(test)]
mod archive_tests;

impl rooms_runtime::wall_clock::WallClock for Deadline {
	fn unix_millis(&self) -> Result<u64, rooms_runtime::wall_clock::Error> {
		use rooms_runtime::wall_clock::Error;
		let time = std::time::SystemTime::now()
			.duration_since(std::time::UNIX_EPOCH)
			.map_err(|_| Error::BeforeEpoch)?;
		u64::try_from(time.as_millis()).map_err(|_| Error::OutOfRange)
	}
}
