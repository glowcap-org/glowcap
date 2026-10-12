//! Trusted read interfaces project shared recursive source/target admission.
use super::{Call, Continuation, ValueBounds, check, invalid};
use crate::{Ref, Result, sys::loam as ffi};

pub struct ReadMethod<'a> {
	pub verb: &'a str,
	/// Interface indices in depth-first reply capability occurrence order.
	/// Empty forbids capabilities. Every returned facet uses the same source.
	pub results: &'a [usize],
}
pub struct ReadInterface<'a> {
	pub methods: &'a [ReadMethod<'a>],
}
pub struct ReadScopeBounds {
	pub interfaces: usize,
	pub methods: usize,
	pub verb_bytes: usize,
	pub result_roles: usize,
	pub targets: usize,
}
impl ReadScopeBounds {
	/// Shared physical contribution to Limits.continuation_bytes. Host actors,
	/// reply storage and temporary Rust/C declaration spines are separate owners.
	pub fn size_bound(&self, arguments: ValueBounds, source_verb_bytes: usize) -> Result<usize> {
		let mut bytes = 0;
		check(
			// SAFETY: this query takes no handle; `&arguments.raw()` is a temporary `GlowcapLoamValueBounds` that lives
			// to the end of this statement, the other arguments are plain integers, and `bytes` is a local
			// out-parameter the callee writes.
			unsafe {
				ffi::glowcap_loam_read_scope_size_bound(
					&arguments.raw(),
					source_verb_bytes,
					self.interfaces,
					self.methods,
					self.verb_bytes,
					self.result_roles,
					self.targets,
					&mut bytes,
				)
			},
			false,
		)?;
		Ok(bytes)
	}
}
impl Call<'_> {
	/// Read callback only. Copy the original admitted intent and interface graph
	/// into shared custody, then declare a facade over this exact target. Later
	/// calls and recursive results recheck source and upstream authority. Effect
	/// verbs belong to receipt execution and must not appear in these declarations.
	/// The returned Ref borrows this callback. Ordinary reply custody owns it.
	pub fn disclose_reads_copying(
		&mut self,
		target: &Ref,
		interfaces: &[ReadInterface<'_>],
		role: usize,
	) -> Result<Ref> {
		// SAFETY: `GlowcapReference` is a plain C struct of integers and null pointers; all-zero is a valid value, and
		// the callee fills it before it is read.
		let mut reference = unsafe { core::mem::zeroed() };
		declarations(interfaces, |declarations| {
			check(
				// SAFETY: `self.raw` is the call handle the C side passed to the enclosing read callback, which
				// `Call`'s lifetime ties to that callback; `&target.to_sys()?` is a temporary `GlowcapReference` that
				// lives to the end of this statement, `declarations` is the closure's slice of read declarations, whose
				// verb and role pointers borrow `interfaces` for the call, and the callee copies it; `reference` is a
				// local out-parameter.
				unsafe {
					ffi::glowcap_loam_call_disclose_reads_copying(
						self.raw,
						&target.to_sys()?,
						declarations.as_ptr(),
						declarations.len(),
						role,
						&mut reference,
					)
				},
				false,
			)
		})?;
		Ok(Ref::from_sys(&reference))
	}
}

impl Continuation {
	/// Copy only the declared read interface over an exact retained target.
	/// Shared custody keeps the original admitted intent alive after this
	/// executor observer drops. Recipients receive no other target methods.
	pub fn project_reads_copying(&self, index: usize, interfaces: &[ReadInterface<'_>], role: usize) -> Result<Ref> {
		// SAFETY: `GlowcapReference` is a plain C struct of integers and null pointers; all-zero is a valid value, and
		// the callee fills it before it is read.
		let mut reference = unsafe { core::mem::zeroed() };
		declarations(interfaces, |declarations| {
			check(
				// SAFETY: `self.raw` is this `Continuation`'s handle from `PendingContinuation::try_take`, released
				// only by its `Drop`; `declarations` is the closure's slice of read declarations, whose verb and role
				// pointers borrow `interfaces` for the call, and the callee copies it; `reference` is a local
				// out-parameter the callee fills.
				unsafe {
					ffi::glowcap_loam_continuation_project_reads_copying(
						self.raw,
						index,
						declarations.as_ptr(),
						declarations.len(),
						role,
						&mut reference,
					)
				},
				false,
			)
		})?;
		Ok(super::continuation::owned_reference(&self.owner, reference))
	}
}

/// Two temporary POD spines, regardless of interface count. Capacity is final
/// before pointers are exposed. All verb and role leaves stay borrowed.
fn declarations<T>(
	interfaces: &[ReadInterface<'_>],
	call: impl FnOnce(&[ffi::GlowcapLoamReadInterface]) -> Result<T>,
) -> Result<T> {
	let count = interfaces.iter().try_fold(0usize, |count, interface| {
		count
			.checked_add(interface.methods.len())
			.ok_or_else(|| invalid("read declaration exceeds address space"))
	})?;
	let mut methods = Vec::with_capacity(count);
	let mut declarations = Vec::with_capacity(interfaces.len());
	for interface in interfaces {
		let offset = methods.len();
		methods.extend(interface.methods.iter().map(|method| ffi::GlowcapLoamReadMethod {
			verb: method.verb.as_ptr(),
			verb_len: method.verb.len(),
			results: method.results.as_ptr(),
			result_count: method.results.len(),
		}));
		declarations.push(ffi::GlowcapLoamReadInterface {
			methods: methods[offset..].as_ptr(),
			method_count: interface.methods.len(),
		});
	}
	call(&declarations)
}
