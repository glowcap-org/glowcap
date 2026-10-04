//! Application callbacks declare requirements and change opaque content.
use super::{Requirement, check, invalid};
use crate::sys::loam as ffi;
use crate::{Argument, Ref, Result, SendArena};
use std::ffi::c_void;
use std::rc::Rc;

#[derive(Clone, Copy)]
pub enum Retry {
	ReadOnly,
	Idempotent,
	Receipt,
}
pub struct Method {
	pub verb: String,
	pub retry: Retry,
}
/// Preparation names actual held authority, or a field in the committed
/// content. Foreign saves verify an already established sturdy URI through Host.
pub enum ReferenceRequest {
	Restore(usize),
	Save { reference: Ref, uri: Option<String> },
}
/// Callbacks run synchronously on the existing Host thread. Requirements are
/// pure declarations. Returned capabilities pass the shared disclosure checks.
pub trait Content {
	fn requirement(&self, payload: &[u8], verb: &str, args: &[Argument]) -> Result<Requirement>;
	fn invoke(&self, call: &mut Call<'_>, payload: &[u8], verb: &str, args: &[Argument]) -> Result<Argument>;
	fn references(&self, _: &[u8], _: usize, _: &str, _: &[Argument]) -> Result<Vec<ReferenceRequest>> {
		Ok(Vec::new())
	}
	/// Requirements for calls forwarded through dependent disclosure. Refusal
	/// is the default; each application explicitly declares supported methods.
	fn dependent_requirement(&self, _: &[u8], _: &str, _: &[Argument]) -> Result<Requirement> {
		Err(invalid("dependent method is not declared"))
	}
}
pub struct Registration {
	pub schema: u64,
	pub version: u32,
	pub methods: Vec<Method>,
	pub content: Box<dyn Content>,
}
pub(super) struct Callback {
	pub content: Box<dyn Content>,
	/// Share the existing Host diagnostic owner through callback retirement.
	/// One Rc and Host id per fixed registration, with no per-call allocation.
	pub diagnostics: Rc<crate::context::ContextInner>,
	pub host_id: u64,
}
pub struct Call<'a> {
	raw: *mut ffi::GlowcapLoamCall,
	lifetime: core::marker::PhantomData<&'a mut ()>,
}
impl Call<'_> {
	pub fn append_reference(&mut self, reference: &Ref) -> Result<()> {
		check(
			unsafe { ffi::glowcap_loam_call_append_reference(self.raw, &reference.to_sys()?) },
			false,
		)
	}
	pub fn replace_reference(&mut self, field: usize, reference: &Ref) -> Result<()> {
		check(
			unsafe { ffi::glowcap_loam_call_replace_reference(self.raw, field, &reference.to_sys()?) },
			false,
		)
	}
	pub fn remove_reference(&mut self, field: usize) -> Result<()> {
		check(
			unsafe { ffi::glowcap_loam_call_remove_reference(self.raw, field) },
			false,
		)
	}
	pub fn replace(&mut self, payload: &[u8]) -> Result<()> {
		check(
			unsafe { ffi::glowcap_loam_call_replace_copying(self.raw, payload.as_ptr(), payload.len()) },
			false,
		)
	}
	pub fn disclose(&mut self, field: usize, dependent: bool) -> Result<Argument> {
		let mut value = unsafe { core::mem::zeroed() };
		check(
			unsafe { ffi::glowcap_loam_call_disclose(self.raw, field, u32::from(dependent), &mut value) },
			false,
		)?;
		unsafe { crate::arg_from_sys(&value) }
	}
}
/// Rust's passable Argument owns its String/Vec leaves and nested spines.
/// This boundary copies callback inputs once into that existing representation;
/// payload and verb remain synchronous borrows, and nothing pins a wire frame.
fn invocation(raw: &ffi::GlowcapLoamInvocation) -> Result<(&[u8], &str, Vec<Argument>)> {
	let payload = if raw.payload_len == 0 {
		&[]
	} else {
		unsafe { core::slice::from_raw_parts(raw.payload, raw.payload_len) }
	};
	let verb = unsafe { core::slice::from_raw_parts(raw.verb, raw.verb_len) };
	let name = std::str::from_utf8(verb).map_err(|_| invalid("method name is not UTF-8"))?;
	Ok((payload, name, unsafe { crate::args_from_sys(raw.args, raw.args_len) }?))
}
fn boundary(callback: Option<&Callback>, operation: &str, f: impl FnOnce() -> Result<()>) -> i32 {
	match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
		Ok(Ok(())) => crate::sys::OK,
		// A deliberate refusal is already returned to the invoking peer. Its
		// local detail is application-owned, not a callerless runtime failure.
		Ok(Err(_)) => ffi::GLOWCAP_LOAM_ERR_APPLICATION,
		Err(payload) => {
			let error = crate::Error::with_detail(crate::sys::ERR_INTERNAL, crate::panic_message(payload.as_ref()));
			if let Some(callback) = callback {
				callback.diagnostics.report_failure(
					crate::FailureLayer::Binding,
					crate::FailureScope::Host,
					callback.host_id,
					0,
					operation,
					&error,
				);
			} else {
				crate::record_runtime_failure(crate::FailureLayer::Binding, operation, error);
			}
			ffi::GLOWCAP_LOAM_ERR_APPLICATION
		}
	}
}
pub(super) unsafe extern "C" fn requirement(
	ctx: *mut c_void,
	input: *const ffi::GlowcapLoamInvocation,
	out: *mut ffi::GlowcapLoamRequirement,
) -> i32 {
	let context = unsafe { &*(ctx.cast::<Callback>()) };
	boundary(Some(context), "loam-content.requirement-panic", || {
		let (payload, verb, args) = invocation(unsafe { &*input })?;
		unsafe { *out = context.content.requirement(payload, verb, &args)?.raw };
		Ok(())
	})
}
pub(super) unsafe extern "C" fn dependent_requirement(
	ctx: *mut c_void,
	input: *const ffi::GlowcapLoamInvocation,
	out: *mut ffi::GlowcapLoamRequirement,
) -> i32 {
	let context = unsafe { &*(ctx.cast::<Callback>()) };
	boundary(Some(context), "loam-content.dependent_requirement-panic", || {
		let (payload, verb, args) = invocation(unsafe { &*input })?;
		unsafe { *out = context.content.dependent_requirement(payload, verb, &args)?.raw };
		Ok(())
	})
}
pub(super) unsafe extern "C" fn references(
	ctx: *mut c_void,
	raw: *mut ffi::GlowcapLoamReferences,
	input: *const ffi::GlowcapLoamInvocation,
) -> i32 {
	let context = unsafe { &*(ctx.cast::<Callback>()) };
	boundary(Some(context), "loam-content.references-panic", || {
		let input = unsafe { &*input };
		let (payload, verb, args) = invocation(input)?;
		for request in context.content.references(payload, input.field_count, verb, &args)? {
			let code = match request {
				ReferenceRequest::Restore(index) => unsafe { ffi::glowcap_loam_references_restore(raw, index) },
				ReferenceRequest::Save { reference, uri } => unsafe {
					ffi::glowcap_loam_references_save_copying(
						raw,
						&reference.to_sys()?,
						uri.as_ref().map_or(core::ptr::null(), |v| v.as_ptr()),
						uri.as_ref().map_or(0, String::len),
					)
				},
			};
			check(code, false)?;
		}
		Ok(())
	})
}
pub(super) unsafe extern "C" fn invoke(
	ctx: *mut c_void,
	raw: *mut ffi::GlowcapLoamCall,
	input: *const ffi::GlowcapLoamInvocation,
) -> i32 {
	let context = unsafe { &*(ctx.cast::<Callback>()) };
	boundary(Some(context), "loam-content.invoke-panic", || {
		let (payload, verb, args) = invocation(unsafe { &*input })?;
		let mut call = Call {
			raw,
			lifetime: core::marker::PhantomData,
		};
		let reply = context.content.invoke(&mut call, payload, verb, &args)?;
		let mut arena = SendArena::default();
		let value = arena.one(&reply)?;
		// The setter copies all bytes and child arrays before the Rust reply dies.
		check(unsafe { ffi::glowcap_loam_call_reply(raw, &value) }, false)
	})
}
pub(super) unsafe extern "C" fn entropy(_: *mut c_void, bytes: *mut u8, len: usize) -> i32 {
	boundary(None, "loam-entropy-panic", || {
		getrandom::fill(unsafe { core::slice::from_raw_parts_mut(bytes, len) })
			.map_err(|error| invalid(&error.to_string()))
	})
}
