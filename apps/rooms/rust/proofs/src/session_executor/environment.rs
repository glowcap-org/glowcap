//! Physical storage and deadlines for the same receipt scenario on both hosts.
#[cfg(not(target_arch = "wasm32"))]
use glowcap::loam::OpenMode;
use glowcap::{
	Ref,
	loam::{Attachment, Limits, Policy, Resource, Schema, Store},
};
use rooms_glowcap::client::Deadline;
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};

#[derive(Clone, Default)]
pub(super) struct Platform {
	pub deadline_ms: Rc<Cell<Option<u64>>>,
	pub suspended: Suspension,
	pub observation_suspended: Suspension,
	pub refuse_observation: Rc<Cell<bool>>,
	pub refused_observations: Rc<Cell<usize>>,
	pub tasks: Rc<RefCell<Vec<tokio::task::AbortHandle>>>,
}
/// Suspension waits for a state change. Self-waking microtasks can prevent a
/// browser from running the IndexedDB callbacks and timers that own progress.
#[derive(Clone)]
pub(super) struct Suspension(tokio::sync::watch::Sender<bool>);
impl Default for Suspension {
	fn default() -> Self {
		Self(tokio::sync::watch::channel(false).0)
	}
}
impl Suspension {
	pub fn set(&self, suspended: bool) {
		self.0.send_replace(suspended);
	}
	pub(super) async fn wait(&self) {
		let mut state = self.0.subscribe();
		while *state.borrow_and_update() {
			state.changed().await.expect("suspension retains its sender");
		}
	}
}
pub(super) struct Task(tokio::task::JoinHandle<()>);
impl Drop for Task {
	fn drop(&mut self) {
		self.0.abort();
	}
}
impl rooms_glowcap::client::Tasks for Platform {
	type Task = Task;
	fn spawn(&self, work: impl core::future::Future<Output = ()> + 'static) -> Task {
		let suspended = self.suspended.clone();
		let task = tokio::task::spawn_local(async move {
			suspended.wait().await;
			work.await;
		});
		self.tasks.borrow_mut().push(task.abort_handle());
		Task(task)
	}
}
impl Deadline for Platform {
	fn monotonic_millis(&self) -> u64 {
		#[cfg(not(target_arch = "wasm32"))]
		{
			rooms_platform::HostPlatform.monotonic_millis()
		}
		#[cfg(target_arch = "wasm32")]
		{
			rooms_browser::platform::Platform::new().unwrap().monotonic_millis()
		}
	}
	async fn within<T>(&self, ms: u64, work: impl core::future::Future<Output = T>) -> Option<T> {
		if self.refuse_observation.get() {
			self.refused_observations.set(self.refused_observations.get() + 1);
			return None;
		}
		self.observation_suspended.wait().await;
		within(self.deadline_ms.get().unwrap_or(ms), work).await
	}
}
impl rooms_runtime::clock::Clock for Platform {
	#[cfg(not(target_arch = "wasm32"))]
	type Instant = tokio::time::Instant;
	#[cfg(target_arch = "wasm32")]
	type Instant = std::time::Duration;
	fn now(&self) -> Self::Instant {
		#[cfg(not(target_arch = "wasm32"))]
		{
			tokio::time::Instant::now()
		}
		#[cfg(target_arch = "wasm32")]
		{
			rooms_runtime::clock::Clock::now(&rooms_browser::platform::Platform::new().unwrap())
		}
	}
	async fn sleep_until(&self, at: Self::Instant) {
		#[cfg(not(target_arch = "wasm32"))]
		tokio::time::sleep_until(at).await;
		#[cfg(target_arch = "wasm32")]
		rooms_runtime::clock::Clock::sleep_until(&rooms_browser::platform::Platform::new().unwrap(), at).await;
	}
}
impl rooms_runtime::wall_clock::WallClock for Platform {
	fn unix_millis(&self) -> core::result::Result<u64, rooms_runtime::wall_clock::Error> {
		#[cfg(not(target_arch = "wasm32"))]
		{
			Ok(std::time::SystemTime::now()
				.duration_since(std::time::UNIX_EPOCH)
				.unwrap()
				.as_millis()
				.try_into()
				.unwrap())
		}
		#[cfg(target_arch = "wasm32")]
		{
			rooms_runtime::wall_clock::WallClock::unix_millis(&rooms_browser::platform::Platform::new().unwrap())
		}
	}
}
pub(super) async fn within<T>(ms: u64, work: impl core::future::Future<Output = T>) -> Option<T> {
	#[cfg(not(target_arch = "wasm32"))]
	{
		tokio::time::timeout(std::time::Duration::from_millis(ms), work)
			.await
			.ok()
	}
	#[cfg(target_arch = "wasm32")]
	{
		rooms_browser::platform::Platform::new().unwrap().within(ms, work).await
	}
}

pub(super) struct Database {
	#[cfg(not(target_arch = "wasm32"))]
	path: std::path::PathBuf,
	#[cfg(target_arch = "wasm32")]
	name: String,
}
#[cfg(target_arch = "wasm32")]
thread_local! {
	static NEXT_DATABASE: Cell<u64> = const { Cell::new(0) };
}
impl Database {
	#[cfg(not(target_arch = "wasm32"))]
	pub fn at(path: std::path::PathBuf) -> Self {
		Self { path }
	}
	#[cfg(not(target_arch = "wasm32"))]
	pub fn path(&self) -> &std::path::Path {
		&self.path
	}
	pub fn new(verb: &str) -> Self {
		#[cfg(not(target_arch = "wasm32"))]
		{
			let nonce = std::time::SystemTime::now()
				.duration_since(std::time::UNIX_EPOCH)
				.unwrap()
				.as_nanos();
			let path = std::env::temp_dir().join(format!("rooms-executor-{verb}-{}-{nonce:x}", std::process::id()));
			std::fs::create_dir(&path).unwrap();
			Self { path }
		}
		#[cfg(target_arch = "wasm32")]
		{
			// Several scenarios exercise the same upstream verb. Keep physical
			// owners distinct while retaining this name for each cold reopen.
			let sequence = NEXT_DATABASE.with(|next| {
				let sequence = next.get();
				next.set(sequence + 1);
				sequence
			});
			Self {
				name: format!("rooms-session-executor-{verb}-{sequence}"),
			}
		}
	}
	pub async fn open(&self, create: bool, schemas: &[Schema], limits: Limits) -> Store {
		#[cfg(not(target_arch = "wasm32"))]
		{
			// Executor scenarios run on the engine Rooms stores in. The storage
			// proofs that reopen a store run on every disk engine.
			let mode = if create { OpenMode::Create } else { OpenMode::Open };
			crate::disk::Disk::Sqlite
				.open(self.path.clone(), [111; 16], mode, schemas, limits)
				.unwrap()
		}
		#[cfg(target_arch = "wasm32")]
		{
			Store::open(&self.name, [111; 16], create, schemas, limits)
				.await
				.unwrap()
		}
	}
	pub fn remove(self) {
		#[cfg(not(target_arch = "wasm32"))]
		std::fs::remove_dir_all(self.path).unwrap();
		// The browser harness deletes these databases after all owners close.
	}
}
pub(super) async fn create(store: &Store, policy: &Policy, schema: Schema, payload: &[u8], depth: u16) -> Resource {
	#[cfg(not(target_arch = "wasm32"))]
	{
		store
			.create_resource(policy, schema, super::session::KIND, payload, depth)
			.unwrap()
	}
	#[cfg(target_arch = "wasm32")]
	{
		store
			.create_resource(policy, schema, super::session::KIND, payload, depth)
			.await
			.unwrap()
	}
}
pub(super) async fn restore(attachment: &Attachment, resource: Resource) -> (Ref, Ref) {
	#[cfg(not(target_arch = "wasm32"))]
	{
		attachment.restore(resource).unwrap()
	}
	#[cfg(target_arch = "wasm32")]
	{
		attachment.restore(resource).await.unwrap()
	}
}
pub(super) async fn close(store: &mut Store) {
	#[cfg(not(target_arch = "wasm32"))]
	store.close().unwrap();
	#[cfg(target_arch = "wasm32")]
	store.close().await.unwrap();
}

/// Let each embedding's effect callbacks run between receipt observations.
/// Browser microtask yielding alone does not admit storage or timer events.
pub(super) async fn yield_turn() {
	#[cfg(not(target_arch = "wasm32"))]
	tokio::task::yield_now().await;
	#[cfg(target_arch = "wasm32")]
	gloo_timers::future::TimeoutFuture::new(0).await;
}
