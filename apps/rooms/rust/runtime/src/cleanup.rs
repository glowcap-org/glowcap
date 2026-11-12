//! Fold cleanup failures without replacing the primary failure. Typed runtime
//! owners retain both sources. Terminal owners render the same ordering.

pub trait Failure: Sized {
	fn with_cleanup(self, cleanup: Self) -> Self;
}
impl Failure for crate::Error {
	fn with_cleanup(self, cleanup: Self) -> Self {
		self.retain(cleanup)
	}
}
impl Failure for String {
	fn with_cleanup(self, cleanup: Self) -> Self {
		format!("{self}; cleanup also failed: {cleanup}")
	}
}

pub fn combine<E: Failure>(primary: Result<(), E>, cleanup: Result<(), E>) -> Result<(), E> {
	match primary {
		Ok(()) => cleanup,
		Err(primary) => Err(failed(primary, cleanup)),
	}
}
pub fn failed<E: Failure>(primary: E, cleanup: Result<(), E>) -> E {
	match cleanup {
		Ok(()) => primary,
		Err(cleanup) => primary.with_cleanup(cleanup),
	}
}
pub fn retain<E: Failure>(result: &mut Result<(), E>, next: Result<(), E>) {
	let prior = std::mem::replace(result, Ok(()));
	*result = combine(prior, next);
}
