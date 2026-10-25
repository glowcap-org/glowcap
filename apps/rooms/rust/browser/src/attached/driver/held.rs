//! Returned handles share a bounded owner through JS and queued work. Final
//! capability releases run on the same LocalSet as creation and invocation.
use super::{Driver, MAX_BYTES, MAX_TASKS, Result};
use std::{ops::Deref, rc::Rc};

pub(crate) struct Held<T>(Rc<Value<T>>);
struct Value<T> {
	value: Option<T>,
	driver: Driver,
	bytes: usize,
}
impl<T> Clone for Held<T> {
	fn clone(&self) -> Self {
		Self(self.0.clone())
	}
}
impl<T> Deref for Held<T> {
	type Target = T;
	fn deref(&self) -> &T {
		// `value` is `Some` until `Value::drop` takes it, so no live handle sees `None`.
		#[allow(clippy::expect_used)]
		self.0.value.as_ref().expect("held value")
	}
}
impl<T> Drop for Value<T> {
	fn drop(&mut self) {
		self.driver.with_local(|| drop(self.value.take()));
		let budget = &self.driver.0.budget;
		budget.handles.set(budget.handles.get() - 1);
		budget.held_bytes.set(budget.held_bytes.get() - self.bytes);
	}
}
impl Driver {
	pub fn hold<T>(&self, value: T, owned_bytes: usize) -> Result<Held<T>> {
		self.require_open()?;
		let budget = &self.0.budget;
		let bytes = owned_bytes.saturating_add(size_of::<Value<T>>() + 2 * size_of::<usize>());
		if budget.handles.get() >= MAX_TASKS || bytes > MAX_BYTES.saturating_sub(budget.held_bytes.get()) {
			return Err("Rooms retained handle capacity is exhausted; release unused handles".into());
		}
		budget.handles.set(budget.handles.get() + 1);
		budget.held_bytes.set(budget.held_bytes.get() + bytes);
		Ok(Held(Rc::new(Value {
			value: Some(value),
			driver: self.clone(),
			bytes,
		})))
	}
}
