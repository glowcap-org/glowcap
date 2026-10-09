//! Callback-borrowed graph pages; Zig owns selection, capture and atomic staging.
use super::{Call, check, invalid};
use crate::{Argument, Ref, Result, sys::loam as ffi};

#[derive(Clone, Copy)]
pub struct PageSchema {
	pub id: u64,
	pub version: u32,
}
pub struct Graph {
	pub schemas: Vec<PageSchema>,
	/// Methods whose requirements need current canonical graph pages, for both
	/// direct invocation and later forwarding through a retained facade.
	pub requirement_verbs: Vec<String>,
	pub max_pages: usize,
	pub max_payload_bytes: usize,
	pub max_edges: usize,
}
impl Graph {
	/// Conservative graph contribution to `Limits.call_bytes` for one complete
	/// preparation and replacement. Each bound covers old and new populations:
	/// `pages` excludes the root, `payload_bytes` includes it, and `fields`
	/// excludes resource bindings and page links. Snapshot/candidate copies,
	/// C page projections, staged edges and physical block overhead are included.
	/// Add reference preparation, managed state, receipts, argument projections,
	/// held occurrences, application callbacks and replies separately. Store
	/// staging, Rust buffers and Host network state have independent owners.
	pub fn call_size_bound(pages: usize, payload_bytes: usize, fields: usize) -> Result<usize> {
		let mut bytes = 0;
		check(
			unsafe { ffi::glowcap_loam_graph_call_size_bound(pages, payload_bytes, fields, &mut bytes) },
			false,
		)?;
		Ok(bytes)
	}
}

/// All borrows end at callback return. A page token cannot be persisted as a
/// durable identity, manufacture authority, or select a row outside this graph.
#[derive(Clone, Copy)]
pub struct Page<'a>(&'a ffi::GlowcapLoamPage);
impl<'a> Page<'a> {
	pub fn schema(self) -> PageSchema {
		PageSchema {
			id: self.0.schema,
			version: self.0.version,
		}
	}
	pub fn payload(self) -> &'a [u8] {
		if self.0.payload_len == 0 {
			&[]
		} else {
			unsafe { core::slice::from_raw_parts(self.0.payload, self.0.payload_len) }
		}
	}
	pub fn field_count(self) -> usize {
		self.0.field_count
	}
	pub(super) fn handle(self) -> *const ffi::GlowcapLoamPageHandle {
		self.0.handle
	}
}

#[derive(Clone, Copy)]
pub struct Pages<'a>(&'a [ffi::GlowcapLoamPage]);
impl<'a> Pages<'a> {
	pub(super) unsafe fn prepared(input: &'a ffi::GlowcapLoamInvocation) -> Result<Option<Self>> {
		match input.graph_prepared {
			0 => Ok(None),
			1 => Ok(Some(unsafe { Self::from_raw(input.pages, input.page_count) })),
			_ => Err(invalid("unknown graph preparation state")),
		}
	}
	pub(super) unsafe fn from_raw(pages: *const ffi::GlowcapLoamPage, count: usize) -> Self {
		Self(if count == 0 {
			&[]
		} else {
			unsafe { core::slice::from_raw_parts(pages, count) }
		})
	}
	pub fn get(self, index: usize) -> Option<Page<'a>> {
		self.0.get(index).map(Page)
	}
	pub fn iter(self) -> impl ExactSizeIterator<Item = Page<'a>> {
		self.0.iter().map(Page)
	}
	pub fn len(self) -> usize {
		self.0.len()
	}
	pub fn is_empty(self) -> bool {
		self.0.is_empty()
	}
}

/// A retained field copies its exact saved edge without restoring the target.
/// Page tokens borrow the active preparation and exclude the resource binding.
pub enum GraphField<'a> {
	Held(Ref),
	Retained { page: Page<'a>, index: usize },
}
impl GraphField<'_> {
	fn to_sys(&self) -> Result<ffi::GlowcapLoamGraphField> {
		Ok(match self {
			Self::Held(reference) => ffi::GlowcapLoamGraphField {
				page: core::ptr::null(),
				index: 0,
				reference: reference.to_sys()?,
			},
			Self::Retained { page, index } => ffi::GlowcapLoamGraphField {
				page: page.handle(),
				index: *index,
				reference: crate::sys::GlowcapReference { id: 0 },
			},
		})
	}
}
pub enum GraphPage<'a> {
	Keep(Page<'a>),
	/// Preserve the exact page and committed fields without restoring targets.
	Update {
		page: Page<'a>,
		payload: &'a [u8],
	},
	Write {
		schema: PageSchema,
		payload: &'a [u8],
		fields: &'a [GraphField<'a>],
	},
}

impl Call<'_> {
	/// Borrow the canonical foreign URI from an explicitly requested restored
	/// recipe. Local and live recipes return None. The borrow ends
	/// at callback return and does not authorize capability disclosure.
	pub fn page_saved_uri(&self, page: Page<'_>, field: usize) -> Result<Option<&str>> {
		let mut uri = core::ptr::null();
		let mut len = 0;
		check(
			unsafe { ffi::glowcap_loam_call_page_saved_uri(self.raw, page.handle(), field, &mut uri, &mut len) },
			false,
		)?;
		if uri.is_null() {
			return Ok(None);
		}
		core::str::from_utf8(unsafe { core::slice::from_raw_parts(uri, len) })
			.map(Some)
			.map_err(|_| invalid("saved URI is not UTF-8"))
	}
	/// Exact authority borrows this retained call until settlement. It may be
	/// used as a candidate field; returning it requires explicit disclosure.
	/// The Rust Ref occurrence allocates its existing release-status cell;
	/// shared Call custody owns the capability retain, with no Rust Host guard.
	pub fn page_reference(&mut self, page: Page<'_>, field: usize) -> Result<Ref> {
		let mut reference = unsafe { core::mem::zeroed() };
		check(
			unsafe { ffi::glowcap_loam_call_page_reference(self.raw, page.handle(), field, &mut reference) },
			false,
		)?;
		Ok(Ref::from_sys(&reference))
	}
	pub fn disclose_page(&mut self, page: Page<'_>, field: usize, dependent: bool) -> Result<Argument> {
		let mut value = unsafe { core::mem::zeroed() };
		check(
			unsafe {
				ffi::glowcap_loam_call_disclose_page(self.raw, page.handle(), field, u32::from(dependent), &mut value)
			},
			false,
		)?;
		unsafe { crate::arg_from_sys(&value) }
	}
	/// Copies the foreign candidate once into Zig's bounded retained call.
	/// Temporary field and descriptor spines retire when this setter returns;
	/// they contain no transaction state or independent persistence authority.
	pub fn replace_graph(&mut self, payload: &[u8], pages: &[GraphPage<'_>]) -> Result<()> {
		let fields: Vec<Vec<_>> = pages
			.iter()
			.map(|page| match page {
				GraphPage::Keep(_) | GraphPage::Update { .. } => Ok(Vec::new()),
				GraphPage::Write { fields, .. } => fields.iter().map(GraphField::to_sys).collect(),
			})
			.collect::<Result<_>>()?;
		let candidates: Vec<_> = pages
			.iter()
			.zip(&fields)
			.map(|(page, fields)| match page {
				GraphPage::Keep(page) => ffi::GlowcapLoamPageReplacement {
					keep: page.handle(),
					schema: 0,
					version: 0,
					payload: core::ptr::null(),
					payload_len: 0,
					fields: core::ptr::null(),
					field_count: 0,
				},
				GraphPage::Update { page, payload } => ffi::GlowcapLoamPageReplacement {
					keep: page.handle(),
					schema: 0,
					version: 0,
					payload: payload.as_ptr(),
					payload_len: payload.len(),
					fields: core::ptr::null(),
					field_count: 0,
				},
				GraphPage::Write { schema, payload, .. } => ffi::GlowcapLoamPageReplacement {
					keep: core::ptr::null(),
					schema: schema.id,
					version: schema.version,
					payload: payload.as_ptr(),
					payload_len: payload.len(),
					fields: fields.as_ptr(),
					field_count: fields.len(),
				},
			})
			.collect();
		check(
			unsafe {
				ffi::glowcap_loam_call_replace_graph_copying(
					self.raw,
					payload.as_ptr(),
					payload.len(),
					candidates.as_ptr(),
					candidates.len(),
				)
			},
			false,
		)
	}
}
