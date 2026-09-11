//! Host-scoped capability identities and Passable value projection.

#[cfg(feature = "async")]
use crate::{sys, Error, Result};

/// An opaque capability identity in one Host. It is never a wire position and
/// its shape does not reveal whether the target is local, remote, or routed
/// through a handoff. `PartialEq` compares that immutable identity only;
/// occurrence-local release state does not change Target equality. The raw id
/// and C layout stay private to the binding.
#[derive(Debug, Clone)]
pub struct Ref {
	id: u64,
	#[cfg(feature = "async")]
	#[allow(dead_code)]
	guard: Option<std::rc::Rc<crate::gc::CapabilityGuard>>,
	released: std::rc::Rc<std::cell::Cell<bool>>,
}

impl PartialEq for Ref {
	fn eq(&self, other: &Self) -> bool {
		self.id == other.id
	}
}

impl Eq for Ref {}

impl Ref {
	pub fn released(&self) -> bool {
		self.released.get()
	}

	#[cfg(feature = "async")]
	pub(crate) fn mark_released(&self) {
		self.released.set(true);
	}

	#[cfg(feature = "async")]
	pub(crate) fn id(&self) -> u64 {
		self.id
	}

	#[cfg(feature = "async")]
	pub(crate) fn guard(&self) -> Option<&crate::gc::CapabilityGuard> {
		self.guard.as_deref()
	}

	#[cfg(feature = "async")]
	pub(crate) fn attach_guard(&mut self, guard: std::rc::Rc<crate::gc::CapabilityGuard>) {
		debug_assert!(self.guard.is_none());
		self.guard = Some(guard);
	}

	#[cfg(feature = "async")]
	pub(crate) fn bare_id(id: u64) -> Ref {
		Ref {
			id,
			#[cfg(feature = "async")]
			guard: None,
			released: std::rc::Rc::new(std::cell::Cell::new(false)),
		}
	}
}

// The C marshaling layer: used only by the async host tier, so it compiles
// only with it — dead-code linting stays live instead of blanket-allowed.
#[cfg(feature = "async")]
impl Ref {
	pub(crate) fn to_sys(&self) -> Result<sys::GlowcapReference> {
		Ok(sys::GlowcapReference { id: self.live_id()? })
	}

	pub(crate) fn live_id(&self) -> Result<u64> {
		if self.released() {
			return Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"this capability was released and is no longer usable".to_string(),
			));
		}
		Ok(self.id)
	}

	pub(crate) fn from_sys(r: &sys::GlowcapReference) -> Ref {
		Ref::bare_id(r.id)
	}
}

/// A passable argument value.
#[derive(Debug, Clone, PartialEq)]
pub enum Argument {
	Integer(i64),
	Float(f64),
	Boolean(bool),
	Bytes(Vec<u8>),
	String(String),
	Symbol(String),
	/// A fulfilled OCapN Error value. This is data, not a Rust `Err`; a broken
	/// remote reply is reported separately by the promise/session API.
	Error(String),
	Void,
	Reference(Ref),
	List(Vec<Argument>),
	Set(Vec<Argument>),
	Tagged {
		tag: String,
		value: Vec<Argument>,
	},
	Keyword(String),
	/// An arbitrary-precision OCapN Integer outside `i64` (ADR-0049): the sign
	/// plus the canonical decimal magnitude (ASCII digits, no leading zero).
	/// Parse `digits` into your own bignum type; glowcap transports and
	/// compares the value, it does not compute with it.
	BigInteger {
		negative: bool,
		digits: String,
	},
	/// An OCapN Struct: unordered, uniquely named String fields. The vector
	/// preserves received order for inspection; OCapN equality ignores it.
	Struct(Vec<(String, Argument)>),
}

impl Argument {
	/// The integer, if this is an [`Argument::Integer`] (an `i64`-range value;
	/// a larger OCapN integer arrives as [`Argument::BigInteger`]).
	pub fn as_i64(&self) -> Option<i64> {
		match self {
			Argument::Integer(v) => Some(*v),
			_ => None,
		}
	}

	/// The float, if this is an [`Argument::Float`].
	pub fn as_f64(&self) -> Option<f64> {
		match self {
			Argument::Float(v) => Some(*v),
			_ => None,
		}
	}

	/// The boolean, if this is an [`Argument::Boolean`].
	pub fn as_bool(&self) -> Option<bool> {
		match self {
			Argument::Boolean(v) => Some(*v),
			_ => None,
		}
	}

	/// The text, if this is an [`Argument::String`].
	pub fn as_str(&self) -> Option<&str> {
		match self {
			Argument::String(s) => Some(s),
			_ => None,
		}
	}

	/// The bytes, if this is an [`Argument::Bytes`].
	pub fn as_bytes(&self) -> Option<&[u8]> {
		match self {
			Argument::Bytes(b) => Some(b),
			_ => None,
		}
	}

	/// The element list, if this is an [`Argument::List`].
	pub fn as_list(&self) -> Option<&[Argument]> {
		match self {
			Argument::List(items) => Some(items),
			_ => None,
		}
	}

	/// Whether this is [`Argument::Void`] (the OCapN void / "no value").
	pub fn is_void(&self) -> bool {
		matches!(self, Argument::Void)
	}
}

// Native-value conversions so an argument list reads as plain Rust values:
// `&[42.into(), "hi".into(), (&cap).into()]`. Integers and floats each take a
// single concrete impl (`i64`, `f64`) so a bare literal still infers, `5.into()`
// is unambiguous. `Ref` already converts in `session.rs`.
impl From<i64> for Argument {
	fn from(v: i64) -> Argument {
		Argument::Integer(v)
	}
}

impl From<f64> for Argument {
	fn from(v: f64) -> Argument {
		Argument::Float(v)
	}
}

impl From<bool> for Argument {
	fn from(v: bool) -> Argument {
		Argument::Boolean(v)
	}
}

impl From<&str> for Argument {
	fn from(v: &str) -> Argument {
		Argument::String(v.to_string())
	}
}

impl From<String> for Argument {
	fn from(v: String) -> Argument {
		Argument::String(v)
	}
}

impl From<Vec<u8>> for Argument {
	fn from(v: Vec<u8>) -> Argument {
		Argument::Bytes(v)
	}
}

impl From<&[u8]> for Argument {
	fn from(v: &[u8]) -> Argument {
		Argument::Bytes(v.to_vec())
	}
}

impl From<()> for Argument {
	fn from(_: ()) -> Argument {
		Argument::Void
	}
}

impl From<Ref> for Argument {
	fn from(r: Ref) -> Argument {
		Argument::Reference(r)
	}
}

impl From<Vec<Argument>> for Argument {
	fn from(items: Vec<Argument>) -> Argument {
		Argument::List(items)
	}
}

/// Owns nested C argument arrays for the duration of one send call. The leaf
/// byte pointers borrow the source [`Argument`]'s own heap payloads (a
/// `String`/`Vec` buffer is address-stable when the enum value moves), so the
/// marshalled tree stays valid as long as the source value and this arena both
/// live.
#[cfg(feature = "async")]
#[derive(Default)]
pub(crate) struct SendArena {
	boxes: Vec<Box<[sys::GlowcapArgument]>>,
}

#[cfg(feature = "async")]
impl SendArena {
	pub(crate) fn build(&mut self, args: &[Argument]) -> Result<(*const sys::GlowcapArgument, usize)> {
		if args.is_empty() {
			return Ok((core::ptr::null(), 0));
		}
		let mut out = Vec::with_capacity(args.len());
		for a in args {
			out.push(self.one(a)?);
		}
		let boxed = out.into_boxed_slice();
		let ptr = boxed.as_ptr();
		let len = boxed.len();
		self.boxes.push(boxed);
		Ok((ptr, len))
	}

	pub(crate) fn one(&mut self, a: &Argument) -> Result<sys::GlowcapArgument> {
		let mut c: sys::GlowcapArgument = unsafe { core::mem::zeroed() };
		match a {
			Argument::Integer(v) => {
				c.kind = sys::ARG_INTEGER;
				c.integer = *v;
			}
			Argument::Float(v) => {
				c.kind = sys::ARG_FLOAT64;
				c.float64 = *v;
			}
			Argument::Boolean(v) => {
				c.kind = sys::ARG_BOOLEAN;
				c.boolean = u32::from(*v);
			}
			Argument::Bytes(b) => set_bytes(&mut c, sys::ARG_BYTES, b),
			Argument::String(s) => set_bytes(&mut c, sys::ARG_STRING, s.as_bytes()),
			Argument::Symbol(s) => set_bytes(&mut c, sys::ARG_SYMBOL, s.as_bytes()),
			Argument::Error(message) => set_bytes(&mut c, sys::ARG_ERROR, message.as_bytes()),
			Argument::Void => c.kind = sys::ARG_VOID,
			Argument::Reference(r) => {
				c.kind = sys::ARG_REFERENCE;
				c.reference = r.to_sys()?;
			}
			Argument::List(items) => {
				c.kind = sys::ARG_LIST;
				let (ptr, len) = self.build(items)?;
				c.items = ptr;
				c.items_len = len;
			}
			Argument::Set(items) => {
				c.kind = sys::ARG_SET;
				let (ptr, len) = self.build(items)?;
				c.items = ptr;
				c.items_len = len;
			}
			Argument::Tagged { tag, value } => {
				c.kind = sys::ARG_TAGGED;
				c.bytes = tag.as_ptr();
				c.bytes_len = tag.len();
				let (ptr, len) = self.build(value)?;
				c.items = ptr;
				c.items_len = len;
			}
			Argument::Keyword(s) => set_bytes(&mut c, sys::ARG_KEYWORD, s.as_bytes()),
			Argument::BigInteger { negative, digits } => {
				set_bytes(&mut c, sys::ARG_BIG_INTEGER, digits.as_bytes());
				c.boolean = u32::from(*negative);
			}
			Argument::Struct(entries) => {
				c.kind = sys::ARG_STRUCT;
				let mut flat = Vec::with_capacity(entries.len() * 2);
				for (key, value) in entries {
					let mut key_arg: sys::GlowcapArgument = unsafe { core::mem::zeroed() };
					set_bytes(&mut key_arg, sys::ARG_STRING, key.as_bytes());
					flat.push(key_arg);
					flat.push(self.one(value)?);
				}
				let boxed = flat.into_boxed_slice();
				c.items = boxed.as_ptr();
				c.items_len = boxed.len();
				self.boxes.push(boxed);
			}
		}
		Ok(c)
	}
}

// A Rust slice's pointer is non-null even at length zero (`NonNull`'s dangling
// stand-in), so a zero-length byte view — a methodless positional verb, an
// empty payload — marshals as the non-NULL `ptr + 0` the host requires, with
// no special case here.
#[cfg(feature = "async")]
fn set_bytes(c: &mut sys::GlowcapArgument, kind: u32, b: &[u8]) {
	c.kind = kind;
	c.bytes = b.as_ptr();
	c.bytes_len = b.len();
}

/// Project a received C argument tree into owned Rust values.
///
/// # Safety
/// `c` must point to a valid `GlowcapArgument` whose borrowed views are live
/// for the duration of the call.
#[cfg(feature = "async")]
pub(crate) unsafe fn arg_from_sys(c: &sys::GlowcapArgument) -> Result<Argument> {
	Ok(match c.kind {
		sys::ARG_INTEGER => Argument::Integer(c.integer),
		sys::ARG_FLOAT64 => Argument::Float(c.float64),
		sys::ARG_BOOLEAN => Argument::Boolean(c.boolean != 0),
		sys::ARG_BYTES => Argument::Bytes(bytes_from_sys(c)),
		sys::ARG_STRING => Argument::String(text_from_sys(c)),
		sys::ARG_SYMBOL => Argument::Symbol(text_from_sys(c)),
		sys::ARG_ERROR => Argument::Error(text_from_sys(c)),
		sys::ARG_REFERENCE => Argument::Reference(Ref::from_sys(&c.reference)),
		sys::ARG_LIST => Argument::List(args_from_sys(c.items, c.items_len)?),
		sys::ARG_SET => Argument::Set(args_from_sys(c.items, c.items_len)?),
		sys::ARG_TAGGED => Argument::Tagged {
			tag: text_from_sys(c),
			value: args_from_sys(c.items, c.items_len)?,
		},
		sys::ARG_KEYWORD => Argument::Keyword(text_from_sys(c)),
		sys::ARG_VOID => Argument::Void,
		sys::ARG_BIG_INTEGER => Argument::BigInteger {
			negative: c.boolean != 0,
			digits: text_from_sys(c),
		},
		sys::ARG_STRUCT => Argument::Struct(struct_from_sys(c.items, c.items_len)?),
		other => {
			return Err(Error::with_detail(
				sys::ERR_INTERNAL,
				format!("glowcap ABI returned unknown argument kind {other}"),
			))
		}
	})
}

#[cfg(feature = "async")]
unsafe fn struct_from_sys(ptr: *const sys::GlowcapArgument, len: usize) -> Result<Vec<(String, Argument)>> {
	if len % 2 != 0 {
		return Err(Error::with_detail(
			sys::ERR_INTERNAL,
			"glowcap ABI returned an odd Struct item count".into(),
		));
	}
	if ptr.is_null() {
		return Ok(Vec::new());
	}
	let mut entries = Vec::with_capacity(len / 2);
	for i in (0..len).step_by(2) {
		let key = &*ptr.add(i);
		if key.kind != sys::ARG_STRING {
			return Err(Error::with_detail(
				sys::ERR_INTERNAL,
				"glowcap ABI returned a non-String Struct key".into(),
			));
		}
		entries.push((text_from_sys(key), arg_from_sys(&*ptr.add(i + 1))?));
	}
	Ok(entries)
}

#[cfg(feature = "async")]
unsafe fn bytes_from_sys(c: &sys::GlowcapArgument) -> Vec<u8> {
	owned_from_view(c.bytes, c.bytes_len)
}

/// Lift a borrowed text view into one owned `String` with one copy. Going
/// through `bytes_from_sys` first paid a second allocation and copy per text
/// leaf, because `from_utf8_lossy` borrows valid UTF-8 and `into_owned` then
/// clones it; the C ABI already validated the text, so the borrowed arm is
/// the one that runs.
///
/// # Safety
/// As `owned_from_view`: a non-null `bytes` must point to `bytes_len`
/// readable bytes for the duration of the call.
#[cfg(feature = "async")]
unsafe fn text_from_sys(c: &sys::GlowcapArgument) -> String {
	if c.bytes.is_null() || c.bytes_len == 0 {
		return String::new();
	}
	String::from_utf8_lossy(core::slice::from_raw_parts(c.bytes, c.bytes_len)).into_owned()
}

/// Copy a borrowed C byte view (`ptr`, `len`) into an owned `Vec`, guarding the
/// null/empty case: `core::slice::from_raw_parts` requires a non-null pointer
/// even for `len == 0`, so a null `bytes` on a successful dequeue becomes an
/// empty `Vec` here rather than instant UB.
///
/// # Safety
/// When `ptr` is non-null and `len > 0`, it must point to `len` initialized,
/// readable bytes valid for the duration of the call.
#[cfg(any(feature = "async", feature = "tcp", feature = "inproc", feature = "onion"))]
pub(crate) unsafe fn owned_from_view(ptr: *const u8, len: usize) -> Vec<u8> {
	if ptr.is_null() || len == 0 {
		Vec::new()
	} else {
		core::slice::from_raw_parts(ptr, len).to_vec()
	}
}

/// Project a borrowed C argument array into owned Rust values.
///
/// # Safety
/// `ptr` must point to `len` valid `GlowcapArgument`s (or be null) whose
/// borrowed views are live for the duration of the call.
#[cfg(feature = "async")]
pub(crate) unsafe fn args_from_sys(ptr: *const sys::GlowcapArgument, len: usize) -> Result<Vec<Argument>> {
	if ptr.is_null() {
		return Ok(Vec::new());
	}
	(0..len).map(|i| arg_from_sys(&*ptr.add(i))).collect()
}

#[cfg(all(test, feature = "async"))]
mod tests {
	use super::*;

	#[test]
	fn released_occurrences_cannot_marshal_even_when_the_identity_has_another_retain() {
		let released = Ref::bare_id(7);
		let clone = released.clone();
		let retained = Ref::bare_id(7);
		released.mark_released();
		assert!(clone.released());
		assert_eq!(clone, retained);
		assert_eq!(retained.to_sys().unwrap().id, 7);
		assert_eq!(
			clone.to_sys().err().expect("released clone refused").kind(),
			crate::ErrorKind::InvalidArgument
		);

		let reference = Argument::Reference(clone);
		for value in [
			reference.clone(),
			Argument::List(vec![reference.clone()]),
			Argument::Set(vec![reference.clone()]),
			Argument::Tagged {
				tag: "held".into(),
				value: vec![reference.clone()],
			},
			Argument::Struct(vec![("held".into(), reference)]),
		] {
			assert_eq!(
				SendArena::default()
					.one(&value)
					.err()
					.expect("nested released clone refused")
					.kind(),
				crate::ErrorKind::InvalidArgument
			);
		}
	}
}
