//! Rooms capability behavior shared by browser hosts and native services.
//! These are application actors above CapTP, not another transport or codec.
pub mod attachment;
pub mod authority;
pub mod carries;
pub mod handoff;
pub mod history;
pub mod inbox;
pub mod invitation;
pub mod line;
pub mod membership;
pub mod message;
pub mod operation;
pub mod policy;
pub mod queries;
pub mod receipt;
pub mod stewardship;

/// A borrowed view of an already decoded protocol argument. The binding adapter
/// implements this over its own value type. Rooms never serializes references
/// into identifiers or owns a second CapTP value representation.
pub trait ArgumentView {
	fn boolean(&self) -> Option<bool>;
	fn is_null(&self) -> bool;
	fn text(&self) -> Option<&str>;
	/// Retained document text may contain isolated UTF-16 surrogates. Adapters
	/// check this byte ceiling before copying. Wire adapters use scalar text.
	fn document(&self, maximum: usize) -> Option<crate::text::DocumentText> {
		let text = self.text()?;
		(text.len() <= maximum).then(|| text.into())
	}
	/// Only wire integers qualify. Floating-point values, including integral
	/// ones, must return None. Integers outside i128 also return None.
	fn integer(&self) -> Option<i128>;
	/// Wire floating-point numbers. Notification metadata admits
	/// safe integral numbers as well as integers. Command indices do not.
	fn float(&self) -> Option<f64>;
	/// Includes every nested occurrence (lists, sets, tagged values, and maps).
	/// The adapter retains custody and releases refused arguments after dispatch.
	fn contains_capability(&self) -> bool;
}

/// Native command text is still text. Numeric-looking strings and Boolean
/// words never acquire the semantics of another wire value.
impl ArgumentView for alloc::string::String {
	fn boolean(&self) -> Option<bool> {
		None
	}
	fn is_null(&self) -> bool {
		false
	}
	fn text(&self) -> Option<&str> {
		Some(self)
	}
	fn integer(&self) -> Option<i128> {
		None
	}
	fn float(&self) -> Option<f64> {
		None
	}
	fn contains_capability(&self) -> bool {
		false
	}
}

/// A borrowed nested value. Returning another view must not clone a capability
/// or copy a decoded list. Only admitted application data is retained.
pub trait ListArgument: ArgumentView + Sized {
	fn list_len(&self) -> Option<usize>;
	fn at(&self, index: usize) -> Option<Self>;
}

pub mod correlation;
