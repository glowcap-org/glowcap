//! The C argument tree one send or tell call lends the Host, and the
//! promise retains minted for it.

use crate::value::Argument;
use crate::{Error, Result, sys};

/// Owns nested C argument arrays for the duration of one send call. The leaf
/// byte pointers borrow the source [`Argument`]'s own heap payloads (a
/// `String`/`Vec` buffer is address-stable when the enum value moves), so the
/// marshalled tree stays valid as long as the source value and this arena both
/// live.
#[derive(Default)]
pub(crate) struct SendArena {
	boxes: Vec<Box<[sys::GlowcapArgument]>>,
	/// The Host a promise argument is minted through; the default arena has
	/// none and refuses a promise.
	host: Option<std::rc::Rc<crate::host::HostShared>>,
	/// The capability retains minted for promise arguments, given back when
	/// the arena drops: the Host's queue holds its own retain once the call is
	/// admitted, and a refused call left nothing that needs them.
	minted: Vec<u64>,
}

impl SendArena {
	/// An arena whose promise arguments are minted through `host`.
	pub(crate) fn for_host(host: &std::rc::Rc<crate::host::HostShared>) -> Self {
		Self {
			boxes: Vec::new(),
			host: Some(std::rc::Rc::clone(host)),
			minted: Vec::new(),
		}
	}

	/// What a promise passes as (ADR-0068): the capability its Host mints for
	/// the vow, in whatever state the vow is in while the promise lives, one
	/// application retain the arena gives back on drop. Refused before any FFI
	/// call when the arena has no Host or the promise is await-only, refused,
	/// or another Host's.
	fn lower_promise(&mut self, promise: &crate::PromiseArgument) -> Result<sys::GlowcapReference> {
		let Some(host) = &self.host else {
			return Err(Error::with_detail(
				sys::ERR_UNSUPPORTED_VALUE,
				"a promise is passable only as a send or tell argument".to_string(),
			));
		};
		let vow = promise.far_vow(host)?;
		let mut reference = sys::GlowcapReference { id: 0 };
		// SAFETY: `host.raw()` is the live Host handle that minted `vow`, as `far_vow` checked; `reference` is a local
		// out-parameter the callee fills.
		crate::host::check_host(unsafe {
			crate::sys::host::glowcap_host_vow_capability(host.raw(), vow, &mut reference)
		})?;
		self.minted.push(reference.id);
		Ok(reference)
	}

	/// The C views of `args`, every promise among them minted through the
	/// Host. A refused build gives its minted retains back first, a release
	/// failure riding the refusal as a secondary.
	pub(crate) fn build(&mut self, args: &[Argument]) -> Result<(*const sys::GlowcapArgument, usize)> {
		match self.items(args) {
			Ok(built) => Ok(built),
			Err(primary) => Err(self.release_beside(primary)),
		}
	}

	/// The FFI call's verdict over this arena's arguments, with every minted
	/// retain given back: the Host's queue holds its own once the call is
	/// admitted, and a refused call left nothing that needs them. Beside a
	/// refusal a release failure rides it as a secondary. After an admitted
	/// call, whose effect stands, it is the Host's to report.
	pub(crate) fn finish<T>(&mut self, verdict: Result<T>) -> Result<T> {
		match verdict {
			Ok(admitted) => {
				let host = self.host.clone();
				if let (Err(cleanup), Some(host)) = (self.release_minted(), host) {
					host.record_background_failure(cleanup);
				}
				Ok(admitted)
			}
			Err(primary) => Err(self.release_beside(primary)),
		}
	}

	fn release_beside(&mut self, primary: Error) -> Error {
		match self.release_minted() {
			Ok(()) => primary,
			Err(cleanup) => primary.with_secondary(cleanup),
		}
	}

	/// Give every minted retain back, the first failure carrying the rest.
	fn release_minted(&mut self) -> Result<()> {
		let Some(host) = &self.host else {
			debug_assert!(self.minted.is_empty());
			return Ok(());
		};
		let mut failure: Option<Error> = None;
		for id in self.minted.drain(..) {
			if let Err(cleanup) = crate::gc::release_ref(host.raw(), id) {
				failure = Some(match failure {
					None => cleanup,
					Some(first) => first.with_secondary(cleanup),
				});
			}
		}
		failure.map_or(Ok(()), Err)
	}

	fn items(&mut self, args: &[Argument]) -> Result<(*const sys::GlowcapArgument, usize)> {
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
		// SAFETY: `GlowcapArgument` is a plain C struct of integers, a float, null-able pointers, and a
		// `GlowcapReference` holding one integer; all-zero is a valid value (null views, zero lengths), and the arms
		// below set the kind and the fields it uses before the value is returned.
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
			Argument::Promise(promise) => {
				c.kind = sys::ARG_REFERENCE;
				c.reference = self.lower_promise(promise)?;
			}
			Argument::List(items) => {
				c.kind = sys::ARG_LIST;
				let (ptr, len) = self.items(items)?;
				c.items = ptr;
				c.items_len = len;
			}
			Argument::Set(items) => {
				c.kind = sys::ARG_SET;
				let (ptr, len) = self.items(items)?;
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
			Argument::Integers(words) => {
				c.kind = sys::ARG_INTEGERS;
				if !words.is_empty() {
					c.bytes = words.as_ptr().cast::<u8>();
					c.bytes_len = core::mem::size_of_val(words.as_slice());
				}
			}
			Argument::Struct(entries) => {
				c.kind = sys::ARG_STRUCT;
				let mut flat = Vec::with_capacity(entries.len() * 2);
				for (key, value) in entries {
					// SAFETY: as the `GlowcapArgument` zeroed in `one` above; `set_bytes` fills the String kind and
					// byte view on the next line before the value is read.
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

impl Drop for SendArena {
	fn drop(&mut self) {
		// Retains `finish` never saw, left by a caller that returned before its FFI call. A drop has no caller to
		// tell, so the failure waits where the Host's close reports it.
		if self.minted.is_empty() {
			return;
		}
		let host = self.host.clone();
		if let (Err(error), Some(host)) = (self.release_minted(), host) {
			host.record_background_failure(error);
		}
	}
}

// A Rust slice's pointer is non-null even at length zero (`NonNull`'s dangling
// stand-in), so a zero-length byte view, a methodless positional verb, an
// empty payload, marshals as the non-NULL `ptr + 0` the host requires, with
// no special case here.
fn set_bytes(c: &mut sys::GlowcapArgument, kind: u32, b: &[u8]) {
	c.kind = kind;
	c.bytes = b.as_ptr();
	c.bytes_len = b.len();
}
