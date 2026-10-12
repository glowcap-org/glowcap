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
	/// Local recipes return no URI. Ordinary restorations pay no URI copy.
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
	/// Exact Host-lifetime custody. Startup must confirm a new live marker first.
	/// Restart refuses the stored field rather than reconstructing authority.
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
	/// [`Self::MAX_URI_BYTES`]. Canonical
	/// expansion, block headers, alignment and growth slack are included.
	/// Add invocation projections, graph snapshots/candidates, held fields,
	/// application callbacks and replies separately. Rust callback buffers and
	/// Host network state have their own owners. This query admits no work.
	pub fn call_size_bound(restores: usize, saves: usize, uri_bytes: usize) -> Result<usize> {
		let mut bytes = 0;
		check(
			// SAFETY: this query takes no handle; `bytes` is a local out-parameter the callee writes.
			unsafe { ffi::glowcap_loam_reference_call_size_bound(restores, saves, uri_bytes, &mut bytes) },
			false,
		)?;
		Ok(bytes)
	}
	/// Additional demand for opt-in URI retention, above normal preparation.
	pub fn uri_call_size_bound(count: usize, uri_bytes: usize) -> Result<usize> {
		let mut bytes = 0;
		check(
			// SAFETY: this query takes no handle; `bytes` is a local out-parameter the callee writes.
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
	/// be in another attachment or peer. No target metadata is certified here.
	Forwarding,
}
/// Borrowed callback input selected by shared hosting. All borrows end when
/// the callback returns. Scalar metadata is descriptive, never admission.
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
/// Borrowed admission description for the actual dispatched operation.
#[derive(Clone, Copy)]
pub struct ForwardWork<'a> {
	pub selector: &'a str,
	pub method: &'a str,
	pub material_bytes: usize,
}
pub trait ForwardAdmission {
	fn admit_forward(&self, call: &mut Call<'_>, work: ForwardWork<'_>) -> Result<()>;
}
/// Callbacks run synchronously on the existing Host thread. Requirements are
/// pure declarations. Returned capabilities pass the shared disclosure checks.
pub trait Content {
	fn requirement(&self, input: Invocation<'_>) -> Result<Requirement>;
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument>;
	/// Forwarded calls skip invoke. Admit their application work after current
	/// source authority succeeds, before the separately held target is dispatched.
	/// This callback stages no replacement and returns no public reply.
	fn forward_admission(&self) -> Option<&dyn ForwardAdmission> {
		None
	}
	fn references(&self, _: Invocation<'_>) -> Result<Vec<ReferenceRequest>> {
		Ok(Vec::new())
	}
	/// Requirements for calls forwarded through dependent disclosure. Refusal
	/// is the default. Each application explicitly declares supported methods.
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
	/// Copy validated source grant and ancestor record names into stack storage.
	/// Accounting data confers no authority and owns no capability occurrence.
	pub fn accounting_path(&self, buffer: &mut [[u8; 33]; 65]) -> Result<usize> {
		const _: () = {
			assert!(core::mem::size_of::<ffi::GlowcapLoamObject>() == core::mem::size_of::<[u8; 33]>());
			assert!(core::mem::align_of::<ffi::GlowcapLoamObject>() == core::mem::align_of::<[u8; 33]>());
		};
		let mut count = 0;
		check(
			// SAFETY: `self.raw` is the call handle the C side passed to the enclosing `invoke`/`admit_forward`
			// callback; `Call`'s lifetime ties this borrow to that callback, which keeps the handle live until it
			// returns; `buffer` is a borrowed `[[u8; 33]; 65]` whose pointer and length stay live for the call,
			// `GlowcapLoamObject` has the size and alignment of `[u8; 33]` (asserted above), and the callee writes at
			// most `buffer.len()` records and the out-parameter `count`.
			unsafe {
				ffi::glowcap_loam_call_accounting_path(self.raw, buffer.as_mut_ptr().cast(), buffer.len(), &mut count)
			},
			false,
		)?;
		Ok(count)
	}
	/// Observe the exporter of exact committed live custody. This borrowed view
	/// creates no connection owner and exposes neither guarded capability.
	pub fn live_dependent_exporter(&self, facet: &Ref) -> Result<Option<crate::Session>> {
		let mut session = core::ptr::null_mut();
		check(
			// SAFETY: `self.raw` is the call handle the C side passed to the enclosing `invoke`/`admit_forward`
			// callback; `Call`'s lifetime ties this borrow to that callback, which keeps the handle live until it
			// returns; the `to_sys()` temporary lives to the end of this statement and the callee only reads it;
			// `session` is an out-parameter the callee fills.
			unsafe { ffi::glowcap_loam_call_live_dependent_exporter(self.raw, &facet.to_sys()?, &mut session) },
			false,
		)?;
		Ok(self.owner.host.exporter_session(session)?.map(crate::Session::view))
	}
	/// Own the exact prepared capability beyond this callback. Its declared
	/// recipe must already have passed preparation. This grants no disclosure.
	pub fn retain_prepared_reference(&self, reference: &Ref) -> Result<Ref> {
		// SAFETY: `GlowcapReference` is a plain C struct of integers and null pointers; all-zero is a valid value, and
		// the callee fills it before it is read.
		let mut raw = unsafe { core::mem::zeroed() };
		check(
			// SAFETY: `self.raw` is the call handle the C side passed to the enclosing `invoke`/`admit_forward`
			// callback; `Call`'s lifetime ties this borrow to that callback, which keeps the handle live until it
			// returns; the `to_sys()` temporary lives to the end of this statement and the callee only reads it; `raw`
			// is an out-parameter the callee fills.
			unsafe { ffi::glowcap_loam_call_retain_prepared_reference(self.raw, &reference.to_sys()?, &mut raw) },
			false,
		)?;
		Ok(super::continuation::owned_reference(self.owner, raw))
	}
	/// Own the actual invoking endpoint. Equal policies or resource identities
	/// cannot substitute for this capability when recovering a saved receipt.
	/// This does not declare authority for the public reply.
	pub fn source(&self) -> Result<Ref> {
		// SAFETY: `GlowcapReference` is a plain C struct of integers and null pointers; all-zero is a valid value, and
		// the callee fills it before it is read.
		let mut raw = unsafe { core::mem::zeroed() };
		// SAFETY: `self.raw` is the call handle the C side passed to the enclosing `invoke`/`admit_forward` callback;
		// `Call`'s lifetime ties this borrow to that callback, which keeps the handle live until it returns; `raw` is
		// an out-parameter the callee fills.
		check(unsafe { ffi::glowcap_loam_call_source(self.raw, &mut raw) }, false)?;
		Ok(super::continuation::owned_reference(self.owner, raw))
	}
	pub fn append_reference(&mut self, reference: &Ref) -> Result<()> {
		check(
			// SAFETY: `self.raw` is the call handle the C side passed to the enclosing `invoke`/`admit_forward`
			// callback; `Call`'s lifetime ties this borrow to that callback, which keeps the handle live until it
			// returns; the `to_sys()` temporary lives to the end of this statement and the callee only reads it.
			unsafe { ffi::glowcap_loam_call_append_reference(self.raw, &reference.to_sys()?) },
			false,
		)
	}
	/// Borrow the facet from this call's matching prepared declaration. Shared
	/// call custody owns its retain. Obtaining it grants no reply disclosure.
	pub fn prepared_live_dependent(&mut self, source: &Ref, target: &Ref) -> Result<Ref> {
		// SAFETY: `GlowcapReference` is a plain C struct of integers and null pointers; all-zero is a valid value, and
		// the callee fills it before it is read.
		let mut reference = unsafe { core::mem::zeroed() };
		check(
			// SAFETY: `self.raw` is the call handle the C side passed to the enclosing `invoke`/`admit_forward`
			// callback; `Call`'s lifetime ties this borrow to that callback, which keeps the handle live until it
			// returns; both `to_sys()` temporaries live to the end of this statement and the callee only reads them;
			// `reference` is an out-parameter the callee fills.
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
			// SAFETY: `self.raw` is the call handle the C side passed to the enclosing `invoke`/`admit_forward`
			// callback; `Call`'s lifetime ties this borrow to that callback, which keeps the handle live until it
			// returns; the three `to_sys()` temporaries live to the end of this statement and the callee only reads
			// them; `matches` is an out-parameter the callee writes.
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
			// SAFETY: `self.raw` is the call handle the C side passed to the enclosing `invoke`/`admit_forward`
			// callback; `Call`'s lifetime ties this borrow to that callback, which keeps the handle live until it
			// returns; the `to_sys()` temporary lives to the end of this statement and the callee only reads it.
			unsafe { ffi::glowcap_loam_call_replace_reference(self.raw, field, &reference.to_sys()?) },
			false,
		)
	}
	pub fn remove_reference(&mut self, field: usize) -> Result<()> {
		check(
			// SAFETY: `self.raw` is the call handle the C side passed to the enclosing `invoke`/`admit_forward`
			// callback; `Call`'s lifetime ties this borrow to that callback, which keeps the handle live until it
			// returns.
			unsafe { ffi::glowcap_loam_call_remove_reference(self.raw, field) },
			false,
		)
	}
	pub fn replace(&mut self, payload: &[u8]) -> Result<()> {
		check(
			// SAFETY: `self.raw` is the call handle the C side passed to the enclosing `invoke`/`admit_forward`
			// callback; `Call`'s lifetime ties this borrow to that callback, which keeps the handle live until it
			// returns; `payload` is a borrowed slice whose pointer and length stay live for the call, and the callee
			// copies it into the call arena before returning.
			unsafe { ffi::glowcap_loam_call_replace_copying(self.raw, payload.as_ptr(), payload.len()) },
			false,
		)
	}
	pub fn disclose(&mut self, field: usize, dependent: bool) -> Result<Argument> {
		// SAFETY: `GlowcapArgument` is a plain C struct of integers and null pointers; all-zero is a valid value, and
		// the callee fills it before it is read.
		let mut value = unsafe { core::mem::zeroed() };
		check(
			// SAFETY: `self.raw` is the call handle the C side passed to the enclosing `invoke`/`admit_forward`
			// callback; `Call`'s lifetime ties this borrow to that callback, which keeps the handle live until it
			// returns; `value` is an out-parameter the callee fills.
			unsafe { ffi::glowcap_loam_call_disclose(self.raw, field, u32::from(dependent), &mut value) },
			false,
		)?;
		// SAFETY: `value` was filled by the successful `disclose` call above and borrows the call arena, which lives
		// until the callback returns, as `arg_from_sys` requires.
		unsafe { crate::arg_from_sys(&value) }
	}
}
/// Rust's passable Argument owns its String/Vec leaves and nested spines.
/// This boundary copies callback inputs once into that existing representation.
/// Payload and verb remain synchronous borrows, and nothing pins a wire frame.
fn invocation<'a>(raw: &'a ffi::GlowcapLoamInvocation, args: &'a [Argument]) -> Result<Invocation<'a>> {
	let payload = if raw.payload_len == 0 {
		&[]
	} else {
		// SAFETY: `raw.payload` and `raw.payload_len` come from the C side's `GlowcapLoamInvocation`, which borrows the
		// payload for the callback; `raw` is borrowed for `'a`, so the slice cannot outlive the callback, and a zero
		// length is handled without dereferencing.
		unsafe { core::slice::from_raw_parts(raw.payload, raw.payload_len) }
	};
	// SAFETY: `raw.verb` and `raw.verb_len` are the verb bytes the C side's `GlowcapLoamInvocation` borrows for the
	// callback; `raw` is borrowed for the same scope as the view.
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
		// SAFETY: `raw` is the `GlowcapLoamInvocation` the C side passed to the callback, so its `graph_prepared`,
		// `pages`, and `page_count` describe pages that stay live until the callback returns.
		graph: unsafe { Pages::prepared(raw) }?,
		verb,
		args,
	})
}
fn with_invocation<T>(raw: &ffi::GlowcapLoamInvocation, f: impl FnOnce(Invocation<'_>) -> Result<T>) -> Result<T> {
	// SAFETY: `raw.args` and `raw.args_len` come from the `GlowcapLoamInvocation` the C side passed to the callback;
	// the argument array and its borrowed views stay live until the callback returns, and `args_from_sys` copies them
	// into owned values.
	let args = unsafe { crate::args_from_sys(raw.args, raw.args_len) }?;
	f(invocation(raw, &args)?)
}
fn boundary(callback: Option<&Callback>, operation: &str, f: impl FnOnce() -> Result<()>) -> i32 {
	match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
		Ok(Ok(())) => crate::sys::OK,
		// Invoke and forward admission stage refusal detail on the
		// call. Other callbacks return the generic application status.
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
	// SAFETY: `ctx` is the pointer to this registration's `Callback`, set as the content's `context` in
	// `registration.rs`; the `Callback` sits in the attachment's `callbacks` vector, which is dropped only after
	// `glowcap_loam_attachment_release`, so it outlives every callback.
	let context = unsafe { &*(ctx.cast::<Callback>()) };
	boundary(Some(context), "loam-content.requirement-panic", || {
		// SAFETY: `input` is the non-null invocation pointer the C side passes for this callback and `out` is its
		// non-null requirement out-parameter; both stay valid until the callback returns.
		unsafe { *out = with_invocation(&*input, |input| context.content.requirement(input))?.raw };
		Ok(())
	})
}
pub(super) unsafe extern "C" fn dependent_requirement(
	ctx: *mut c_void,
	input: *const ffi::GlowcapLoamInvocation,
	out: *mut ffi::GlowcapLoamRequirement,
) -> i32 {
	// SAFETY: `ctx` is the pointer to this registration's `Callback`, set as the content's `context` in
	// `registration.rs`; the `Callback` sits in the attachment's `callbacks` vector, which is dropped only after
	// `glowcap_loam_attachment_release`, so it outlives every callback.
	let context = unsafe { &*(ctx.cast::<Callback>()) };
	boundary(Some(context), "loam-content.dependent_requirement-panic", || {
		// SAFETY: `input` is the non-null invocation pointer the C side passes for this callback and `out` is its
		// non-null requirement out-parameter; both stay valid until the callback returns.
		unsafe { *out = with_invocation(&*input, |input| context.content.dependent_requirement(input))?.raw };
		Ok(())
	})
}
pub(super) unsafe extern "C" fn references(
	ctx: *mut c_void,
	raw: *mut ffi::GlowcapLoamReferences,
	input: *const ffi::GlowcapLoamInvocation,
) -> i32 {
	// SAFETY: `ctx` is the pointer to this registration's `Callback`, set as the content's `context` in
	// `registration.rs`; the `Callback` sits in the attachment's `callbacks` vector, which is dropped only after
	// `glowcap_loam_attachment_release`, so it outlives every callback.
	let context = unsafe { &*(ctx.cast::<Callback>()) };
	boundary(Some(context), "loam-content.references-panic", || {
		// SAFETY: `input` is the non-null invocation pointer the C side passes for this callback; it stays valid until
		// the callback returns.
		let input = unsafe { &*input };
		for request in with_invocation(input, |input| context.content.references(input))? {
			let code = match request {
				// SAFETY: `raw` is the references handle the C side passed to this callback and stays live until it
				// returns.
				ReferenceRequest::Restore(index) => unsafe { ffi::glowcap_loam_references_restore(raw, index) },
				ReferenceRequest::RestorePage { page, field } => {
					// SAFETY: `input` is the invocation the C side passed to this callback; its prepared pages stay
					// live until the callback returns.
					let selected = unsafe { Pages::prepared(input) }?
						.and_then(|pages| pages.get(page))
						.ok_or_else(|| invalid("page is not in the prepared graph"))?;
					// SAFETY: `raw` is the references handle the C side passed to this callback and stays live until it
					// returns; `selected.handle()` is a page token borrowed from this callback's prepared graph.
					unsafe { ffi::glowcap_loam_references_restore_page(raw, selected.handle(), field) }
				}
				ReferenceRequest::RestorePageWithUri { page, field } => {
					// SAFETY: `input` is the invocation the C side passed to this callback; its prepared pages stay
					// live until the callback returns.
					let selected = unsafe { Pages::prepared(input) }?
						.and_then(|pages| pages.get(page))
						.ok_or_else(|| invalid("page is not in the prepared graph"))?;
					// SAFETY: `raw` is the references handle the C side passed to this callback and stays live until it
					// returns; `selected.handle()` is a page token borrowed from this callback's prepared graph.
					unsafe { ffi::glowcap_loam_references_restore_page_with_uri(raw, selected.handle(), field) }
				}
				ReferenceRequest::InspectPageUri { page, field } => {
					// SAFETY: `input` is the invocation the C side passed to this callback; its prepared pages stay
					// live until the callback returns.
					let selected = unsafe { Pages::prepared(input) }?
						.and_then(|pages| pages.get(page))
						.ok_or_else(|| invalid("page is not in the prepared graph"))?;
					// SAFETY: `raw` is the references handle the C side passed to this callback and stays live until it
					// returns; `selected.handle()` is a page token borrowed from this callback's prepared graph.
					unsafe { ffi::glowcap_loam_references_inspect_page_uri(raw, selected.handle(), field) }
				}
				// SAFETY: `raw` is the references handle the C side passed to this callback and stays live until it
				// returns; the `to_sys()` temporary lives to the end of this arm and the callee only reads it; the
				// `uri` pointer and length come from a live `String` (or null and zero) that the callee copies before
				// returning.
				ReferenceRequest::Save { reference, uri } => unsafe {
					ffi::glowcap_loam_references_save_copying(
						raw,
						&reference.to_sys()?,
						uri.as_ref().map_or(core::ptr::null(), |v| v.as_ptr()),
						uri.as_ref().map_or(0, String::len),
					)
				},
				// SAFETY: `raw` is the references handle the C side passed to this callback and stays live until it
				// returns; the `to_sys()` temporary lives to the end of this arm and the callee only reads it.
				ReferenceRequest::SaveLive(reference) => unsafe {
					ffi::glowcap_loam_references_save_live(raw, &reference.to_sys()?)
				},
				// SAFETY: `raw` is the references handle the C side passed to this callback and stays live until it
				// returns; both `to_sys()` temporaries live to the end of this arm and the callee only reads them.
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
	// SAFETY: `ctx` is the pointer to this registration's `Callback`, set as the content's `context` in
	// `registration.rs`; the `Callback` sits in the attachment's `callbacks` vector, which is dropped only after
	// `glowcap_loam_attachment_release`, so it outlives every callback.
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
		// SAFETY: `input` is the non-null invocation pointer the C side passes for this callback; it stays valid until
		// the callback returns.
		let reply = match with_invocation(unsafe { &*input }, |input| context.content.invoke(&mut call, input)) {
			Ok(reply) => reply,
			Err(error) => {
				// Preserve application-owned detail for the invoking peer. A failed
				// setter (oversized detail or exhausted arena) keeps the ABI's generic
				// refusal; it never changes the failed call into success.
				if let Some(detail) = error.detail.as_deref() {
					// SAFETY: `raw` is the call handle the C side passed to this callback and stays live until it
					// returns; `detail` is a borrowed `str` whose pointer and length stay live for the call, and the
					// callee copies it into the call arena.
					let _ = unsafe { ffi::glowcap_loam_call_refuse_copying(raw, detail.as_ptr(), detail.len()) };
				}
				return Err(error);
			}
		};
		let mut arena = SendArena::default();
		let value = arena.one(&reply)?;
		// The setter copies all bytes and child arrays before the Rust reply dies.
		// SAFETY: `raw` is the call handle the C side passed to this callback and stays live until it returns; `value`
		// borrows `reply`, which outlives the call, and the callee copies it into the call arena before returning.
		check(unsafe { ffi::glowcap_loam_call_reply(raw, &value) }, false)
	})
}

pub(super) unsafe extern "C" fn admit_forward(
	ctx: *mut c_void,
	raw: *mut ffi::GlowcapLoamCall,
	selector: *const u8,
	selector_len: usize,
	method: *const u8,
	method_len: usize,
	material_bytes: usize,
) -> i32 {
	// SAFETY: `ctx` is the pointer to this registration's `Callback`, set as the content's `context` in
	// `registration.rs`; the `Callback` sits in the attachment's `callbacks` vector, which is dropped only after
	// `glowcap_loam_attachment_release`, so it outlives every callback.
	let context = unsafe { &*(ctx.cast::<Callback>()) };
	boundary(Some(context), "loam-content.forward-admission-panic", || {
		let owner = context
			.owner
			.upgrade()
			.ok_or_else(|| invalid("content attachment is closed"))?;
		let mut call = Call {
			raw,
			owner: &owner,
			lifetime: core::marker::PhantomData,
		};
		// SAFETY: `selector` and `selector_len` are the selector bytes the C side passed to this callback; they stay
		// valid until it returns, and the slice does not escape it.
		let selector = std::str::from_utf8(unsafe { core::slice::from_raw_parts(selector, selector_len) })
			.map_err(|_| invalid("forward selector is not UTF-8"))?;
		// SAFETY: `method` and `method_len` are the method bytes the C side passed to this callback; they stay valid
		// until it returns, and the slice does not escape it.
		let method = std::str::from_utf8(unsafe { core::slice::from_raw_parts(method, method_len) })
			.map_err(|_| invalid("forward method is not UTF-8"))?;
		context
			.content
			.forward_admission()
			.ok_or_else(|| invalid("forward admission is not registered"))?
			.admit_forward(
				&mut call,
				ForwardWork {
					selector,
					method,
					material_bytes,
				},
			)
			.inspect_err(|error| {
				if let Some(detail) = error.detail.as_deref() {
					// SAFETY: `raw` is the call handle the C side passed to this callback and stays live until it
					// returns; `detail` is a borrowed `str` whose pointer and length stay live for the call, and the
					// callee copies it into the call arena.
					let _ = unsafe { ffi::glowcap_loam_call_refuse_copying(raw, detail.as_ptr(), detail.len()) };
				}
			})
	})
}
pub(super) unsafe extern "C" fn entropy(_: *mut c_void, bytes: *mut u8, len: usize) -> i32 {
	boundary(None, "loam-entropy-panic", || {
		// SAFETY: `bytes` and `len` are the writable entropy buffer the C side passed to this callback; it stays valid
		// and exclusively ours until the callback returns.
		getrandom::fill(unsafe { core::slice::from_raw_parts_mut(bytes, len) })
			.map_err(|error| invalid(&error.to_string()))
	})
}
