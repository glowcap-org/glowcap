//! Folding a cleanup's failure onto the failure it followed, once, for every
//! owner that still speaks `String`. The first cause stays first; a cleanup
//! that also failed is named after it rather than replacing it, so the
//! operator reads what went wrong before what could not be undone.

/// The outcome of `primary` followed by `cleanup`.
pub fn combine(primary: Result<(), String>, cleanup: Result<(), String>) -> Result<(), String> {
	match (primary, cleanup) {
		(Ok(()), outcome) | (outcome, Ok(())) => outcome,
		(Err(primary), Err(cleanup)) => Err(format!("{primary}; cleanup also failed: {cleanup}")),
	}
}

/// `combine` in place, for an owner folding several cleanups in turn.
pub fn retain(result: &mut Result<(), String>, next: Result<(), String>) {
	let prior = std::mem::replace(result, Ok(()));
	*result = combine(prior, next);
}
