//! Bounded result cache and cancellation-safe request coalescing.
use futures_util::{FutureExt, future::LocalBoxFuture, future::Shared};
use std::{
	cell::RefCell,
	collections::{HashMap, VecDeque},
	future::Future,
	rc::Rc,
	time::{Duration, Instant},
};

struct Cached<T> {
	value: T,
	expires: Instant,
	bytes: usize,
}

struct Pending<T: Clone> {
	id: u64,
	waiters: usize,
	future: Shared<LocalBoxFuture<'static, T>>,
}

pub(super) struct Pool<T: Clone> {
	cache: HashMap<String, Cached<T>>,
	order: VecDeque<String>,
	pending: HashMap<String, Pending<T>>,
	next: u64,
	bytes: usize,
	max_entries: usize,
	max_bytes: usize,
	weight: fn(&T) -> usize,
	ttl: fn(&T) -> Duration,
}

impl<T: Clone> Pool<T> {
	pub fn new(
		max_entries: usize,
		max_bytes: usize,
		weight: fn(&T) -> usize,
		ttl: fn(&T) -> Duration,
	) -> Rc<RefCell<Self>> {
		Rc::new(RefCell::new(Self {
			cache: HashMap::new(),
			order: VecDeque::new(),
			pending: HashMap::new(),
			next: 1,
			bytes: 0,
			max_entries,
			max_bytes,
			weight,
			ttl,
		}))
	}

	fn get(&mut self, key: &str) -> Option<T> {
		let now = Instant::now();
		if self.cache.get(key).is_some_and(|entry| entry.expires <= now) {
			self.remove(key);
			return None;
		}
		let value = self.cache.get(key)?.value.clone();
		self.touch(key);
		Some(value)
	}

	fn insert(&mut self, key: String, value: T) {
		let ttl = (self.ttl)(&value);
		if ttl.is_zero() {
			return;
		}
		let bytes = (self.weight)(&value);
		if bytes > self.max_bytes {
			return;
		}
		self.remove(&key);
		while self.cache.len() >= self.max_entries || bytes > self.max_bytes.saturating_sub(self.bytes) {
			let Some(oldest) = self.order.pop_front() else { break };
			self.remove(&oldest);
		}
		self.bytes += bytes;
		self.order.push_back(key.clone());
		self.cache.insert(
			key,
			Cached {
				value,
				expires: Instant::now() + ttl,
				bytes,
			},
		);
	}

	fn touch(&mut self, key: &str) {
		self.order.retain(|held| held != key);
		self.order.push_back(key.to_owned());
	}

	fn remove(&mut self, key: &str) {
		if let Some(entry) = self.cache.remove(key) {
			self.bytes -= entry.bytes;
		}
		self.order.retain(|held| held != key);
	}
}

/// Forget a completed result before an explicit retry. An in-flight generation
/// remains the single owner of its effect, so simultaneous retries still
/// coalesce instead of multiplying network work.
pub fn refresh<T: Clone>(pool: &Rc<RefCell<Pool<T>>>, key: &str) {
	pool.borrow_mut().remove(key);
}

struct Ticket<T: Clone> {
	pool: Rc<RefCell<Pool<T>>>,
	key: String,
	id: u64,
	completed: bool,
}

impl<T: Clone> Ticket<T> {
	fn complete(mut self, value: T) {
		let matched = self
			.pool
			.borrow()
			.pending
			.get(&self.key)
			.is_some_and(|pending| pending.id == self.id);
		if matched {
			let mut pool = self.pool.borrow_mut();
			pool.pending.remove(&self.key);
			pool.insert(self.key.clone(), value);
		}
		self.completed = true;
	}
}

impl<T: Clone> Drop for Ticket<T> {
	fn drop(&mut self) {
		if self.completed {
			return;
		}
		let mut pool = self.pool.borrow_mut();
		let remove = if let Some(pending) = pool.pending.get_mut(&self.key).filter(|pending| pending.id == self.id) {
			pending.waiters -= 1;
			pending.waiters == 0
		} else {
			false
		};
		if remove {
			pool.pending.remove(&self.key);
		}
	}
}

/// Reuse a fresh result or one in-flight effect. The last cancelled waiter
/// removes the pending owner and therefore drops the unpolled network future.
/// Completion caches only the exact pending generation it started.
pub async fn coalesce<T, F>(pool: &Rc<RefCell<Pool<T>>>, key: String, make: F) -> T
where
	T: Clone + 'static,
	F: Future<Output = T> + 'static,
{
	let (id, future) = {
		let mut pool = pool.borrow_mut();
		if let Some(value) = pool.get(&key) {
			return value;
		}
		if let Some(pending) = pool.pending.get_mut(&key) {
			pending.waiters += 1;
			(pending.id, pending.future.clone())
		} else {
			let id = pool.next;
			pool.next = pool.next.wrapping_add(1).max(1);
			let future = make.boxed_local().shared();
			pool.pending.insert(
				key.clone(),
				Pending {
					id,
					waiters: 1,
					future: future.clone(),
				},
			);
			(id, future)
		}
	};
	let ticket = Ticket {
		pool: pool.clone(),
		key,
		id,
		completed: false,
	};
	let value = future.await;
	ticket.complete(value.clone());
	value
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::{cell::Cell, rc::Rc};

	fn pool() -> Rc<RefCell<Pool<u8>>> {
		Pool::new(2, 2, |_| 1, |_| Duration::from_secs(60))
	}

	#[tokio::test(flavor = "current_thread")]
	async fn caches_completed_values_with_lru_bounds() {
		let pool = pool();
		let calls = Rc::new(Cell::new(0));
		for (key, value) in [("a", 1), ("b", 2), ("a", 9), ("c", 3)] {
			let calls = calls.clone();
			let found = coalesce(&pool, key.into(), async move {
				calls.set(calls.get() + 1);
				value
			})
			.await;
			assert_eq!(found, if key == "a" && value == 9 { 1 } else { value });
		}
		assert_eq!(calls.get(), 3);
		assert!(!pool.borrow().cache.contains_key("b"));
	}

	#[tokio::test(flavor = "current_thread")]
	async fn cancellation_retires_the_pending_generation() {
		let pool = pool();
		let mut pending = Box::pin(coalesce(&pool, "a".into(), core::future::pending::<u8>()));
		assert!(futures_util::FutureExt::now_or_never(pending.as_mut()).is_none());
		drop(pending);
		assert!(pool.borrow().pending.is_empty());
	}

	#[tokio::test(flavor = "current_thread")]
	async fn concurrent_waiters_share_one_effect() {
		let pool = pool();
		let calls = Rc::new(Cell::new(0));
		let first_calls = calls.clone();
		let second_calls = calls.clone();
		let first = coalesce(&pool, "a".into(), async move {
			first_calls.set(first_calls.get() + 1);
			tokio::task::yield_now().await;
			7
		});
		let second = coalesce(&pool, "a".into(), async move {
			second_calls.set(second_calls.get() + 1);
			9
		});
		let (first, second) = tokio::join!(first, second);
		assert_eq!((first, second), (7, 7));
		assert_eq!(calls.get(), 1);
	}

	#[tokio::test(flavor = "current_thread")]
	async fn explicit_refresh_forgets_only_the_completed_result() {
		let pool = pool();
		assert_eq!(coalesce(&pool, "a".into(), async { 1 }).await, 1);
		refresh(&pool, "a");
		assert_eq!(coalesce(&pool, "a".into(), async { 2 }).await, 2);
	}
}
