//! Two bounded input slots bridge asynchronous IndexedDB reads to Zig.
//! Metadata stays cached for read/lookup/restore fronts; the other slot is the
//! current supplied row. Writes copy directly to JavaScript and enter the same
//! active transaction, so no Rust overlay or transaction-sized snapshot exists.
use super::super::{check, invalid};
use crate::{Result, sys::loam as ffi};
use core::ffi::c_void;
use js_sys::{Array, Uint8Array};
use std::{cell::RefCell, rc::Rc};
use wasm_bindgen::{JsCast, JsValue};

const MAX_KEY_BYTES: usize = 35;
/// Cumulative adapter costs. Input includes fixed Plan state and owned row/key
/// bytes. Submitted writes exclude IndexedDB's own cloning and reclamation.
#[derive(Clone, Copy, Debug, Default)]
pub struct StorageStatistics {
	pub transactions: u64,
	pub planning_passes: u64,
	pub database_rows: u64,
	pub emitted_writes: u64,
	pub copied_bytes: u64,
	pub peak_input_bytes: usize,
	pub input_capacity_bytes: usize,
	pub max_transaction_write_bytes: usize,
}
struct Row {
	key: Vec<u8>,
	value: Option<Vec<u8>>,
}
impl Row {
	fn bytes(&self) -> usize {
		self.key.len() + self.value.as_ref().map_or(0, Vec::len)
	}
}
pub(super) struct Plan {
	metadata: Option<Row>,
	row: Option<Row>,
	missing: Option<Vec<u8>>,
	failure: Option<crate::Error>,
	rows: JsValue,
	write: bool,
	row_limit: usize,
	write_bytes: usize,
	statistics: Rc<RefCell<StorageStatistics>>,
}
impl Plan {
	pub fn input_capacity(row_limit: usize) -> Result<usize> {
		// Metadata key/value, one row key/value and one missing key coexist.
		row_limit
			.checked_add(core::mem::size_of::<Self>() + ffi::GLOWCAP_LOAM_METADATA_SIZE + 1 + 2 * MAX_KEY_BYTES)
			.ok_or_else(|| invalid("Loam transaction input size overflow"))
	}
	pub fn new(row_limit: usize, write: bool, statistics: Rc<RefCell<StorageStatistics>>) -> Result<Self> {
		let capacity = Self::input_capacity(row_limit)?;
		{
			let mut statistics = statistics.borrow_mut();
			statistics.input_capacity_bytes = statistics.input_capacity_bytes.max(capacity);
		}
		Ok(Self {
			metadata: None,
			row: None,
			missing: None,
			failure: None,
			rows: JsValue::UNDEFINED,
			write,
			row_limit,
			write_bytes: 0,
			statistics,
		})
	}
	fn input_bytes(&self) -> usize {
		core::mem::size_of::<Self>()
			+ self.metadata.as_ref().map_or(0, Row::bytes)
			+ self.row.as_ref().map_or(0, Row::bytes)
			+ self.missing.as_ref().map_or(0, Vec::len)
	}
	pub fn input(&mut self, rows: JsValue, key: JsValue, value: JsValue) -> Result<()> {
		self.rows = rows;
		self.missing = None;
		self.failure = None;
		{
			let mut statistics = self.statistics.borrow_mut();
			statistics.planning_passes = statistics.planning_passes.saturating_add(1);
		}
		if key.is_undefined() {
			return Ok(());
		}
		if !key.is_instance_of::<Uint8Array>() || (!value.is_undefined() && !value.is_instance_of::<Uint8Array>()) {
			return Err(invalid("IndexedDB Loam row is not a byte array"));
		}
		// Wrap arrays before admission; their constructors would clone early.
		let key = key.unchecked_into::<Uint8Array>();
		let value = (!value.is_undefined()).then(|| value.unchecked_into::<Uint8Array>());
		if key.length() == 0 || key.length() as usize > MAX_KEY_BYTES {
			return Err(invalid("invalid Loam physical key"));
		}
		let length = value.as_ref().map_or(0, |v| v.length() as usize);
		let metadata = key.length() == 1 && key.get_index(0) == b'm';
		let limit = if metadata {
			ffi::GLOWCAP_LOAM_METADATA_SIZE
		} else {
			self.row_limit
		};
		if length > limit {
			return Err(invalid("Loam transaction input row budget exceeded"));
		}
		if metadata {
			self.metadata = None;
		} else {
			self.row = None;
		}
		let row = Row {
			key: key.to_vec(),
			value: value.map(|v| v.to_vec()),
		};
		let charged = row.bytes();
		if metadata {
			self.metadata = Some(row);
		} else {
			self.row = Some(row);
		}
		let mut statistics = self.statistics.borrow_mut();
		statistics.database_rows = statistics.database_rows.saturating_add(1);
		statistics.copied_bytes = statistics.copied_bytes.saturating_add(charged as u64);
		statistics.peak_input_bytes = statistics.peak_input_bytes.max(self.input_bytes());
		Ok(())
	}
	pub fn get(&mut self, key: &[u8]) -> Result<Option<&[u8]>> {
		if let Some(row) = self.metadata.iter().chain(self.row.iter()).find(|row| row.key == key) {
			return Ok(row.value.as_deref());
		}
		if key.is_empty() || key.len() > MAX_KEY_BYTES {
			return Err(invalid("invalid Loam physical key"));
		}
		self.missing = Some(key.to_vec());
		let mut statistics = self.statistics.borrow_mut();
		statistics.copied_bytes = statistics.copied_bytes.saturating_add(key.len() as u64);
		statistics.peak_input_bytes = statistics.peak_input_bytes.max(self.input_bytes());
		Err(crate::Error::with_detail(
			crate::sys::WOULD_BLOCK,
			"transaction row is not loaded".into(),
		))
	}
	pub fn put(&mut self, key: &[u8], value: Option<&[u8]>) -> Result<()> {
		if !self.write || key.is_empty() || key.len() > MAX_KEY_BYTES || value.is_some_and(|v| v.len() > self.row_limit)
		{
			return Err(invalid("Loam transaction write row budget exceeded"));
		}
		let charged = key
			.len()
			.checked_add(value.map_or(0, <[u8]>::len))
			.ok_or_else(|| invalid("Loam transaction row size overflow"))?;
		let total = self
			.write_bytes
			.checked_add(charged)
			.ok_or_else(|| invalid("Loam transaction write size overflow"))?;
		// JS receives owned byte arrays before cached input invalidation. The
		// payload may borrow that row; IndexedDB serializes it synchronously.
		let js_key = Uint8Array::from(key);
		let js_value = value.map(|v| Uint8Array::from(v));
		super::js_put(&self.rows, &js_key, js_value.as_ref()).map_err(super::js_error)?;
		if self.metadata.as_ref().is_some_and(|row| row.key == key) {
			self.metadata = None;
		}
		if self.row.as_ref().is_some_and(|row| row.key == key) {
			self.row = None;
		}
		self.write_bytes = total;
		let mut statistics = self.statistics.borrow_mut();
		statistics.emitted_writes = statistics.emitted_writes.saturating_add(1);
		statistics.copied_bytes = statistics.copied_bytes.saturating_add(charged as u64);
		statistics.max_transaction_write_bytes = statistics.max_transaction_write_bytes.max(total);
		Ok(())
	}
	pub fn remove(&mut self, key: &[u8]) -> Result<()> {
		self.put(key, None)
	}
	pub fn output(&self, code: i32) -> Result<JsValue> {
		let output = Array::new();
		if code == crate::sys::WOULD_BLOCK {
			let key = self
				.missing
				.as_ref()
				.ok_or_else(|| invalid("planner suspended without a missing row"))?;
			let mut statistics = self.statistics.borrow_mut();
			statistics.copied_bytes = statistics.copied_bytes.saturating_add(key.len() as u64);
			output.push(&0.into());
			output.push(&Uint8Array::from(key.as_slice()));
		} else {
			if let Err(error) = check(code, false) {
				return Err(if let Some(cause) = &self.failure {
					error.with_secondary(cause.clone())
				} else {
					error
				});
			}
			output.push(&1.into());
		}
		Ok(output.into())
	}
	pub fn context(&mut self) -> *mut c_void {
		(self as *mut Self).cast()
	}
}

/// Row borrows last until the next KV callback. The shared cursor consumes
/// backend bytes before another callback or a wait for the next input.
pub(super) unsafe extern "C" fn callback(
	context: *mut c_void,
	op: u32,
	key: *const u8,
	len: usize,
	value: *const ffi::GlowcapLoamBytes,
	out: *mut ffi::GlowcapLoamBytes,
) -> i32 {
	// SAFETY: the caller supplies a live Plan and the C evaluator's bounded
	// borrowed key/value storage. No callback yields or runs application code.
	let plan = unsafe { &mut *context.cast::<Plan>() };
	let key = unsafe { core::slice::from_raw_parts(key, len) };
	let result = match op {
		0 => plan.get(key).map(|value| unsafe {
			*out = ffi::GlowcapLoamBytes {
				data: value.map_or(core::ptr::null(), |v| v.as_ptr()),
				len: value.map_or(0, |v| v.len()),
				present: u32::from(value.is_some()),
			};
		}),
		1 => {
			let value = unsafe { &*value };
			plan.put(
				key,
				Some(if value.len == 0 {
					&[]
				} else {
					unsafe { core::slice::from_raw_parts(value.data, value.len) }
				}),
			)
		}
		2 => plan.remove(key),
		_ => Err(invalid("unknown Loam KV operation")),
	};
	result.map_or_else(
		|error| {
			let code = error.code;
			if code != crate::sys::WOULD_BLOCK {
				plan.failure = Some(error);
			}
			code
		},
		|()| crate::sys::OK,
	)
}
