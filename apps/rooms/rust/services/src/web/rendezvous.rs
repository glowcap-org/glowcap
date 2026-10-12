//! A registration owns one waiting byte channel. Promotion moves that channel
//! and its early hello to exactly one dialer. The registry holds no capability.
use rooms_application::admission::{Charge, Class, Profile, Registry as Budgets};
use rooms_platform::websocket::WsBytes;
use std::{
	cell::RefCell,
	collections::{BTreeMap, VecDeque},
	rc::Rc,
	time::{Duration, Instant},
};
use tokio::{
	io::{AsyncReadExt, AsyncWriteExt},
	sync::{oneshot, watch},
};

type Socket = WsBytes<hyper_util::rt::TokioIo<hyper::upgrade::Upgraded>>;
type Claim = oneshot::Sender<Held>;
pub(super) struct Held {
	pub socket: Socket,
	pub early: std::io::Cursor<Vec<u8>>,
}
struct Entry {
	ticket: u64,
	claim: oneshot::Sender<Claim>,
}
struct State {
	queues: BTreeMap<String, VecDeque<Entry>>,
	count: usize,
	next: u64,
	/// Depleted destinations survive their last registration until refill.
	/// The independent row cap refuses new accounting rather than resetting debt.
	claims: Budgets<[u8; 32]>,
	start: Instant,
}
pub(super) struct Registry {
	state: RefCell<State>,
	capacity: usize,
	per_identity: usize,
}
pub(super) struct Registration {
	registry: Rc<Registry>,
	identity: String,
	ticket: u64,
	claim: oneshot::Receiver<Claim>,
}
impl Registry {
	#[cfg(test)]
	pub fn new(capacity: usize, per_identity: usize) -> Rc<Self> {
		Self::with_profile(capacity, per_identity, Profile::default())
	}
	pub fn with_profile(capacity: usize, per_identity: usize, profile: Profile) -> Rc<Self> {
		Rc::new(Self {
			state: RefCell::new(State {
				queues: BTreeMap::new(),
				count: 0,
				next: 0,
				start: Instant::now(),
				claims: Budgets::new(profile, capacity),
			}),
			capacity,
			per_identity,
		})
	}
	pub fn register(self: &Rc<Self>, identity: &str) -> Result<Registration, &'static str> {
		if !designator(identity) {
			return Err("rooms: invalid rendezvous identity\n");
		}
		let mut state = self.state.borrow_mut();
		if state.count >= self.capacity || state.queues.get(identity).is_some_and(|q| q.len() >= self.per_identity) {
			return Err("rooms: rendezvous registration capacity exceeded\n");
		}
		let ticket = state
			.next
			.checked_add(1)
			.ok_or("rooms: rendezvous ticket space exhausted\n")?;
		state.next = ticket;
		let (tx, rx) = oneshot::channel();
		state
			.queues
			.entry(identity.into())
			.or_default()
			.push_back(Entry { ticket, claim: tx });
		state.count += 1;
		Ok(Registration {
			registry: self.clone(),
			identity: identity.into(),
			ticket,
			claim: rx,
		})
	}
	pub fn take(&self, identity: &str) -> Result<oneshot::Receiver<Held>, String> {
		let now = self
			.state
			.borrow()
			.start
			.elapsed()
			.as_millis()
			.try_into()
			.unwrap_or(u64::MAX);
		self.take_at(identity, now)
	}
	fn take_at(&self, identity: &str, now: u64) -> Result<oneshot::Receiver<Held>, String> {
		let mut state = self.state.borrow_mut();
		if !state.queues.contains_key(identity) {
			return Err("rendezvous peer is not registered".into());
		}
		let mut key = [0; 32];
		for (index, byte) in key.iter_mut().enumerate() {
			*byte = identity
				.get(index * 2..index * 2 + 2)
				.and_then(|pair| u8::from_str_radix(pair, 16).ok())
				.ok_or("rendezvous identity is not a hexadecimal key")?;
		}
		state
			.claims
			.admit(
				&[Charge {
					key,
					class: Class::Rendezvous,
					amount: 1,
				}],
				now,
			)
			.map_err(|refusal| refusal.reason_at(rooms_application::admission::Owner::Http))?;
		loop {
			let queue = state
				.queues
				.get_mut(identity)
				.ok_or("rendezvous peer is not registered")?;
			let entry = queue.pop_front().ok_or("rendezvous peer is not registered")?;
			if queue.is_empty() {
				state.queues.remove(identity);
			}
			state.count -= 1;
			let (tx, rx) = oneshot::channel();
			if entry.claim.send(tx).is_ok() {
				return Ok(rx);
			}
		}
	}
}
impl Drop for Registration {
	fn drop(&mut self) {
		let mut state = self.registry.state.borrow_mut();
		if let Some(queue) = state.queues.get_mut(&self.identity)
			&& let Some(at) = queue.iter().position(|e| e.ticket == self.ticket)
		{
			queue.remove(at);
			let empty = queue.is_empty();
			state.count -= 1;
			if empty {
				state.queues.remove(&self.identity);
			}
		}
	}
}
impl Registration {
	pub async fn hold(mut self, mut socket: Socket, mut stop: watch::Receiver<bool>) -> Result<(), String> {
		let mut early = Vec::new();
		let mut buffer = [0u8; 8192];
		let result = loop {
			tokio::select! {
				biased;
				_ = super::stopped(&mut stop) => break Ok(()),
				claim = &mut self.claim => match claim {
					Ok(claim) => {
						let held = Held { socket, early: std::io::Cursor::new(early) };
						match claim.send(held) {
							Ok(()) => return Ok(()),
							Err(held) => { socket = held.socket; break Err("rendezvous dialer went away".into()); }
						}
					}
					Err(_) => break Ok(()),
				},
				read = socket.read(&mut buffer) => match read {
					Ok(0) => break Ok(()),
					Ok(n) if n <= super::upgrade::MAX_MESSAGE - early.len() => early.extend_from_slice(&buffer[..n]),
					Ok(_) => break Err("rendezvous early bytes exceed their budget".into()),
					Err(error) => break Err(error.to_string()),
				}
			}
		};
		let closed = tokio::time::timeout(Duration::from_secs(3), socket.shutdown())
			.await
			.map_err(|_| "rendezvous close timed out".to_owned())
			.and_then(|r| r.map_err(|e| e.to_string()));
		crate::cleanup::combine(result, closed)
	}
}
pub(super) fn designator(value: &str) -> bool {
	value.len() == 64 && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn claim_accounting_does_not_grow_with_retired_registrations() {
		let registry = Registry::new(2, 1);
		for index in 0..20 {
			let identity = format!("{index:064x}");
			let registration = registry.register(&identity).unwrap();
			let _claim = registry.take(&identity);
			drop(registration);
		}
		assert!(
			registry.state.borrow().claims.len() <= 2,
			"retired identities grew the claim budget table"
		);
	}
	#[test]
	fn replacing_the_last_registration_does_not_reset_debt() {
		let registry = Registry::new(2, 1);
		let identity = format!("{:064x}", 1);
		for _ in 0..4 {
			let registration = registry.register(&identity).unwrap();
			assert!(registry.take_at(&identity, 0).is_ok());
			drop(registration);
		}
		let _registration = registry.register(&identity).unwrap();
		let error = registry
			.take_at(&identity, 1)
			.err()
			.expect("depletion survives recreation");
		assert_eq!(
			rooms_application::failure::Failure::parse(&error)
				.unwrap()
				.retry_advice()
				.unwrap()
				.retry_ms,
			14_999
		);
		assert!(registry.take_at(&identity, 15_000).is_ok());
	}
}
