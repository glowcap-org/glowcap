//! Host-scoped Rust application data, separate from FFI protocol state.
use super::*;
use std::any::{Any, TypeId};
#[derive(Default)]
pub(super) struct States(RefCell<HashMap<TypeId, Entry>>);
enum Entry {
	Initializing,
	Ready(Rc<dyn Any>),
}
struct Initialization<'a> {
	states: &'a States,
	key: TypeId,
	committed: bool,
}
impl Drop for Initialization<'_> {
	fn drop(&mut self) {
		if !self.committed {
			self.states.0.borrow_mut().remove(&self.key);
		}
	}
}
impl Host {
	/// Share one Rust application value of T across every clone of this Host.
	/// The Host retains it until its Rust wrapper is dropped. Store application
	/// data here, not a Host/session owner that would form a reference cycle.
	/// No protocol state or FFI lifecycle hook is created. Initializers may
	/// initialize other types. Recursive initialization of T returns an error.
	pub fn application_state<T: 'static>(&self, make: impl FnOnce() -> T) -> Result<Rc<T>> {
		self.shared.guard_handle()?;
		let states = &self.shared.applications;
		let key = TypeId::of::<T>();
		{
			let mut entries = states.0.borrow_mut();
			match entries.get(&key) {
				Some(Entry::Ready(value)) => {
					return Ok(value
						.clone()
						.downcast::<T>()
						.unwrap_or_else(|_| unreachable!("TypeId owns this value")));
				}
				Some(Entry::Initializing) => {
					return Err(Error::with_detail(
						sys::ERR_INTERNAL,
						"recursive Host application-state initialization".into(),
					));
				}
				None => {
					entries.insert(key, Entry::Initializing);
				}
			}
		}
		// No table borrow crosses application code. Unwind removes the reservation.
		let mut init = Initialization {
			states,
			key,
			committed: false,
		};
		let value = Rc::new(make());
		states.0.borrow_mut().insert(key, Entry::Ready(value.clone()));
		init.committed = true;
		Ok(value)
	}
	/// Whether both handles share the same Rust Host owner. Restoring the
	/// same durable key into another Host does not make its session graph equal.
	pub fn same_host(&self, other: &Host) -> bool {
		Rc::ptr_eq(&self.shared, &other.shared)
	}
}
#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn application_state_is_per_host_and_survives_wrapper_churn() {
		let host = Host::from_seed([37; 32]).unwrap();
		let clone = host.clone();
		let other = Host::from_seed([37; 32]).unwrap();
		assert!(host.same_host(&clone));
		assert!(!host.same_host(&other));
		let first = host.application_state(|| Cell::new(7u32)).unwrap();
		first.set(8);
		drop(first);
		assert_eq!(clone.application_state(|| Cell::new(0u32)).unwrap().get(), 8);
		assert_eq!(other.application_state(|| Cell::new(0u32)).unwrap().get(), 0);
		let nested = host
			.application_state(|| {
				assert!(clone.application_state(|| 0u64).is_err());
				assert_eq!(*clone.application_state(|| 0u8).unwrap(), 0);
				3u64
			})
			.unwrap();
		assert_eq!(*nested, 3);
		assert!(
			std::panic::catch_unwind(std::panic::AssertUnwindSafe(
				|| host.application_state::<u16>(|| panic!("initializer"))
			))
			.is_err()
		);
		assert_eq!(*host.application_state(|| 12u16).unwrap(), 12);
		let retained = Rc::downgrade(&host.application_state(|| Cell::new(0u32)).unwrap());
		assert!(retained.upgrade().is_some());
		drop((nested, host, clone));
		assert!(retained.upgrade().is_none());
	}
}
