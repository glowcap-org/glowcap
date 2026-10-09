//! Application callbacks declare requirements and change opaque content.
use super::content_graph::{Graph, Pages};
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
	/// Page position in this callback's prepared graph, never an object name.
	RestorePage {
		page: usize,
		field: usize,
	},
	/// Exact restoration with its canonical foreign URI retained in the Call.
	/// Local recipes return no URI; ordinary restorations pay no URI copy.
	RestorePageWithUri {
		page: usize,
		field: usize,
	},
	/// Inspect the canonical recipe without restoring authority or dialing.
	/// Local and live custody return no URI, including expired live fields.
	InspectPageUri {
		page: usize,
		field: usize,
	},
	Save {
		reference: Ref,
		uri: Option<String>,
	},
	/// Exact Host-lifetime custody. Startup must confirm a new live marker first;
	/// restart refuses the stored field rather than reconstructing authority.
	SaveLive(Ref),
	/// Prepare and save one stable live facet governed by the actual source and
	/// target. Later calls use shared dependent admission for both authorities.
	SaveLiveDependent {
		source: Ref,
		target: Ref,
	},
}
impl ReferenceRequest {
	/// The longest URI a recipe stores, supplied or canonical.
	pub const MAX_URI_BYTES: usize = ffi::GLOWCAP_LOAM_MAX_URI_BYTES;

	/// Conservative reference contribution to `Limits.call_bytes` for one
	/// preparation and staging attempt, including C request/URI copies,
	/// save/restore state, recipe bytes and one temporary parser window. Counts bound declared occurrences.
	/// `uri_bytes` bounds supplied and stored inputs, at most
	/// [`Self::MAX_URI_BYTES`]; canonical
	/// expansion, block headers, alignment and growth slack are included.
	/// Add invocation projections, graph snapshots/candidates, held fields,
	/// application callbacks and replies separately. Rust callback buffers and
	/// Host network state have their own owners. This query admits no work.
	pub fn call_size_bound(restores: usize, saves: usize, uri_bytes: usize) -> Result<usize> {
		let mut bytes = 0;
		check(
			unsafe { ffi::glowcap_loam_reference_call_size_bound(restores, saves, uri_bytes, &mut bytes) },
			false,
		)?;
		Ok(bytes)
	}
	/// Additional demand for opt-in URI retention, above normal preparation.
	pub fn uri_call_size_bound(count: usize, uri_bytes: usize) -> Result<usize> {
		let mut bytes = 0;
		check(
			unsafe { ffi::glowcap_loam_reference_uri_call_size_bound(count, uri_bytes, &mut bytes) },
			false,
		)?;
		Ok(bytes)
	}
}
/// A descriptive resource name within its authority domain. Copying it does
/// not retain a capability or admit a later effect.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ResourceId {
	/// Authority-domain identity in big-endian byte order.
	pub owner: [u8; 16],
	pub slot: u32,
	pub generation: u64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BoundResource {
	pub id: ResourceId,
	pub kind: u64,
	/// Canonical resource row's Store-qualified key, never invocation authority.
	pub object: [u8; 33],
	/// Current owner resource-graph revision, independent of grant changes.
	pub revision: u64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Delivery {
	Local,
	/// Only the mediating source is described. The separately held target may
	/// be in another attachment or peer; no target metadata is certified here.
	Forwarding,
}
/// Borrowed callback input selected by shared hosting. All borrows end when
/// the callback returns; scalar metadata is descriptive, never admission.
#[derive(Clone, Copy)]
pub struct Invocation<'a> {
	pub bound_resource: BoundResource,
	pub delivery: Delivery,
	/// Selected content row's Store-qualified key.
	pub content: [u8; 33],
	pub content_revision: u64,
	pub payload: &'a [u8],
	pub field_count: usize,
	pub graph: Option<Pages<'a>>,
	pub verb: &'a str,
	pub args: &'a [Argument],
}
/// Callbacks run synchronously on the existing Host thread. Requirements are
/// pure declarations. Returned capabilities pass the shared disclosure checks.
pub trait Content {
	fn requirement(&self, input: Invocation<'_>) -> Result<Requirement>;
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument>;
	fn references(&self, _: Invocation<'_>) -> Result<Vec<ReferenceRequest>> {
		Ok(Vec::new())
	}
	/// Requirements for calls forwarded through dependent disclosure. Refusal
	/// is the default; each application explicitly declares supported methods.
	fn dependent_requirement(&self, _: Invocation<'_>) -> Result<Requirement> {
		Err(invalid("dependent method is not declared"))
	}
}
pub struct Registration {
	pub schema: u64,
	pub version: u32,
	pub methods: Vec<Method>,
	pub content: Box<dyn Content>,
	pub graph: Option<Graph>,
}
pub(super) struct Callback {
	pub content: Box<dyn Content>,
	/// Share the existing Host diagnostic owner through callback retirement.
	/// One Rc and Host id per fixed registration, with no per-call allocation.
	pub diagnostics: Rc<crate::context::ContextInner>,
	pub host_id: u64,
	pub owner: std::rc::Weak<super::AttachmentInner>,
}
pub struct Call<'a> {
	pub(super) raw: *mut ffi::GlowcapLoamCall,
	pub(super) owner: &'a Rc<super::AttachmentInner>,
	lifetime: core::marker::PhantomData<&'a mut ()>,
}
impl Call<'_> {
	/// Observe the exporter of exact committed live custody. This borrowed view
	/// creates no connection owner and exposes neither guarded capability.
	pub fn live_dependent_exporter(&self, facet: &Ref) -> Result<Option<crate::Session>> {
		let mut session = core::ptr::null_mut();
		check(
			unsafe { ffi::glowcap_loam_call_live_dependent_exporter(self.raw, &facet.to_sys()?, &mut session) },
			false,
		)?;
		Ok(self.owner.host.exporter_session(session)?.map(crate::Session::view))
	}
	/// Own the exact prepared capability beyond this callback. Its declared
	/// recipe must already have passed preparation. This grants no disclosure.
	pub fn retain_prepared_reference(&self, reference: &Ref) -> Result<Ref> {
		let mut raw = unsafe { core::mem::zeroed() };
		check(
			unsafe { ffi::glowcap_loam_call_retain_prepared_reference(self.raw, &reference.to_sys()?, &mut raw) },
			false,
		)?;
		Ok(super::continuation::owned_reference(self.owner, raw))
	}
	/// Own the actual invoking endpoint. Equal policies or resource identities
	/// cannot substitute for this capability when recovering a saved receipt.
	/// This does not declare authority for the public reply.
	pub fn source(&self) -> Result<Ref> {
		let mut raw = unsafe { core::mem::zeroed() };
		check(unsafe { ffi::glowcap_loam_call_source(self.raw, &mut raw) }, false)?;
		Ok(super::continuation::owned_reference(self.owner, raw))
	}
	pub fn append_reference(&mut self, reference: &Ref) -> Result<()> {
		check(
			unsafe { ffi::glowcap_loam_call_append_reference(self.raw, &reference.to_sys()?) },
			false,
		)
	}
	/// Borrow the facet from this call's matching prepared declaration. Shared
	/// call custody owns its retain. Obtaining it grants no reply disclosure.
	pub fn prepared_live_dependent(&mut self, source: &Ref, target: &Ref) -> Result<Ref> {
		let mut reference = unsafe { core::mem::zeroed() };
		check(
			unsafe {
				ffi::glowcap_loam_call_prepared_live_dependent(
					self.raw,
					&source.to_sys()?,
					&target.to_sys()?,
					&mut reference,
				)
			},
			false,
		)?;
		Ok(Ref::from_sys(&reference))
	}
	/// Compare a committed live facet's actual guarded pair without constructing
	/// another facet. Descriptive identities cannot satisfy this check.
	pub fn matches_live_dependent(&mut self, facet: &Ref, source: &Ref, target: &Ref) -> Result<bool> {
		let mut matches = 0;
		check(
			unsafe {
				ffi::glowcap_loam_call_matches_live_dependent(
					self.raw,
					&facet.to_sys()?,
					&source.to_sys()?,
					&target.to_sys()?,
					&mut matches,
				)
			},
			false,
		)?;
		Ok(matches != 0)
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
fn invocation<'a>(raw: &'a ffi::GlowcapLoamInvocation, args: &'a [Argument]) -> Result<Invocation<'a>> {
	let payload = if raw.payload_len == 0 {
		&[]
	} else {
		unsafe { core::slice::from_raw_parts(raw.payload, raw.payload_len) }
	};
	let verb = unsafe { core::slice::from_raw_parts(raw.verb, raw.verb_len) };
	let verb = std::str::from_utf8(verb).map_err(|_| invalid("method name is not UTF-8"))?;
	let resource = &raw.bound_resource;
	Ok(Invocation {
		bound_resource: BoundResource {
			id: ResourceId {
				owner: resource.id.owner,
				slot: resource.id.slot,
				generation: resource.id.generation,
			},
			kind: resource.kind,
			object: resource.object.key,
			revision: resource.revision,
		},
		delivery: match raw.delivery {
			0 => Delivery::Local,
			1 => Delivery::Forwarding,
			_ => return Err(invalid("unknown callback delivery")),
		},
		content: raw.content.key,
		content_revision: raw.content_revision,
		payload,
		field_count: raw.field_count,
		graph: unsafe { Pages::prepared(raw) }?,
		verb,
		args,
	})
}
fn with_invocation<T>(raw: &ffi::GlowcapLoamInvocation, f: impl FnOnce(Invocation<'_>) -> Result<T>) -> Result<T> {
	let args = unsafe { crate::args_from_sys(raw.args, raw.args_len) }?;
	f(invocation(raw, &args)?)
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
		unsafe { *out = with_invocation(&*input, |input| context.content.requirement(input))?.raw };
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
		unsafe { *out = with_invocation(&*input, |input| context.content.dependent_requirement(input))?.raw };
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
		for request in with_invocation(input, |input| context.content.references(input))? {
			let code = match request {
				ReferenceRequest::Restore(index) => unsafe { ffi::glowcap_loam_references_restore(raw, index) },
				ReferenceRequest::RestorePage { page, field } => {
					let selected = unsafe { Pages::prepared(input) }?
						.and_then(|pages| pages.get(page))
						.ok_or_else(|| invalid("page is not in the prepared graph"))?;
					unsafe { ffi::glowcap_loam_references_restore_page(raw, selected.handle(), field) }
				}
				ReferenceRequest::RestorePageWithUri { page, field } => {
					let selected = unsafe { Pages::prepared(input) }?
						.and_then(|pages| pages.get(page))
						.ok_or_else(|| invalid("page is not in the prepared graph"))?;
					unsafe { ffi::glowcap_loam_references_restore_page_with_uri(raw, selected.handle(), field) }
				}
				ReferenceRequest::InspectPageUri { page, field } => {
					let selected = unsafe { Pages::prepared(input) }?
						.and_then(|pages| pages.get(page))
						.ok_or_else(|| invalid("page is not in the prepared graph"))?;
					unsafe { ffi::glowcap_loam_references_inspect_page_uri(raw, selected.handle(), field) }
				}
				ReferenceRequest::Save { reference, uri } => unsafe {
					ffi::glowcap_loam_references_save_copying(
						raw,
						&reference.to_sys()?,
						uri.as_ref().map_or(core::ptr::null(), |v| v.as_ptr()),
						uri.as_ref().map_or(0, String::len),
					)
				},
				ReferenceRequest::SaveLive(reference) => unsafe {
					ffi::glowcap_loam_references_save_live(raw, &reference.to_sys()?)
				},
				ReferenceRequest::SaveLiveDependent { source, target } => unsafe {
					ffi::glowcap_loam_references_save_live_dependent(raw, &source.to_sys()?, &target.to_sys()?)
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
		let owner = context
			.owner
			.upgrade()
			.ok_or_else(|| invalid("content attachment is closed"))?;
		let mut call = Call {
			raw,
			owner: &owner,
			lifetime: core::marker::PhantomData,
		};
		let reply = with_invocation(unsafe { &*input }, |input| context.content.invoke(&mut call, input))?;
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
