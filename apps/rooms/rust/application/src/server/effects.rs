//! What every server policy asks of its adapter in the same words. The
//! rooms and the directory each answer their own effects; the ones both
//! answer live here so an adapter handles one shape.

/// A capability the adapter gives back on the connection it lives on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Release<C, R> {
	pub connection: C,
	pub capability: R,
}
