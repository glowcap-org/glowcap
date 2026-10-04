//! Bounded transaction-local snapshots bridge asynchronous IndexedDB requests
//! to the synchronous Zig batch evaluator. Each database row copies once into
//! Rust; staged writes copy once from Zig and once into JavaScript for IndexedDB.
//! Borrows survive the entire evaluator call, including superseded proposals.
use super::super::{check, invalid};
use crate::{Result, sys::loam as ffi};
use core::ffi::c_void;
use js_sys::{Array, Uint8Array};
use std::{cell::RefCell, rc::Rc};
use wasm_bindgen::{JsCast, JsValue};

const MAX_ROWS: usize = 1024;
/// Cumulative adapter costs, including repeated evaluation. Saturation preserves
/// the storage contract even when a lifetime counter reaches its integer limit.
#[derive(Clone, Copy, Debug, Default)]
pub struct StorageStatistics {
	pub transactions: u64,
	pub planning_passes: u64,
	pub database_rows: u64,
	pub copied_bytes: u64,
	pub peak_snapshot_bytes: usize,
	pub peak_overlay_bytes: usize,
}
struct Row {
	key: Vec<u8>,
	value: Option<Vec<u8>>,
}
pub(super) struct Plan {
	rows: Vec<Row>,
	writes: Vec<Row>,
	missing: Option<Vec<u8>>,
	failure: Option<crate::Error>,
	bytes: usize,
	write_bytes: usize,
	limit: usize,
	statistics: Rc<RefCell<StorageStatistics>>,
}
impl Plan {
	pub fn new(limit: usize, statistics: Rc<RefCell<StorageStatistics>>) -> Self {
		Self {
			rows: Vec::new(),
			writes: Vec::new(),
			missing: None,
			failure: None,
			bytes: 0,
			write_bytes: 0,
			limit,
			statistics,
		}
	}
	pub fn input(&mut self, key: JsValue, value: JsValue) -> Result<()> {
		self.writes.clear();
		self.write_bytes = 0;
		self.missing = None;
		self.failure = None;
		let mut statistics = self.statistics.borrow_mut();
		statistics.planning_passes = statistics.planning_passes.saturating_add(1);
		if key.is_undefined() {
			return Ok(());
		}
		if !key.is_instance_of::<Uint8Array>() || (!value.is_undefined() && !value.is_instance_of::<Uint8Array>()) {
			return Err(invalid("IndexedDB Loam row is not a byte array"));
		}
		// The instance checks above permit wrapping the existing arrays.
		// Calling their constructors would clone before budget admission.
		let key = key.unchecked_into::<Uint8Array>();
		let value = (!value.is_undefined()).then(|| value.unchecked_into::<Uint8Array>());
		let charged = (key.length() as usize)
			.checked_add(value.as_ref().map_or(0, |v| v.length() as usize))
			.ok_or_else(|| invalid("Loam transaction row size overflow"))?;
		if self.rows.len() == MAX_ROWS || charged > self.limit.saturating_sub(self.bytes) {
			return Err(invalid("Loam transaction snapshot budget exceeded"));
		}
		if key.length() == 0 || key.length() > 35 {
			return Err(invalid("invalid Loam physical key"));
		}
		self.bytes += charged;
		statistics.database_rows = statistics.database_rows.saturating_add(1);
		statistics.copied_bytes = statistics.copied_bytes.saturating_add(charged as u64);
		statistics.peak_snapshot_bytes = statistics.peak_snapshot_bytes.max(self.bytes);
		self.rows.push(Row {
			key: key.to_vec(),
			value: value.map(|v| v.to_vec()),
		});
		Ok(())
	}
	pub fn get(&mut self, key: &[u8]) -> Result<Option<&[u8]>> {
		if let Some(row) = self
			.writes
			.iter()
			.rev()
			.chain(self.rows.iter())
			.find(|row| row.key == key)
		{
			return Ok(row.value.as_deref());
		}
		if self.rows.len() == MAX_ROWS {
			return Err(invalid("Loam transaction row budget exceeded"));
		}
		let mut statistics = self.statistics.borrow_mut();
		statistics.copied_bytes = statistics.copied_bytes.saturating_add(key.len() as u64);
		self.missing = Some(key.to_vec());
		Err(crate::Error::with_detail(
			crate::sys::WOULD_BLOCK,
			"transaction row is not loaded".into(),
		))
	}
	pub fn put(&mut self, key: &[u8], value: Option<&[u8]>) -> Result<()> {
		let charged = key
			.len()
			.checked_add(value.map_or(0, |v| v.len()))
			.ok_or_else(|| invalid("Loam transaction write size overflow"))?;
		if self.writes.len() == MAX_ROWS || charged > self.limit.saturating_sub(self.bytes + self.write_bytes) {
			return Err(invalid("Loam transaction overlay budget exceeded"));
		}
		self.write_bytes += charged;
		let mut statistics = self.statistics.borrow_mut();
		statistics.copied_bytes = statistics.copied_bytes.saturating_add(charged as u64);
		statistics.peak_overlay_bytes = statistics.peak_overlay_bytes.max(self.write_bytes);
		self.writes.push(Row {
			key: key.to_vec(),
			value: value.map(<[u8]>::to_vec),
		});
		Ok(())
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
			let mut statistics = self.statistics.borrow_mut();
			statistics.copied_bytes = statistics.copied_bytes.saturating_add(self.write_bytes as u64);
			output.push(&1.into());
			let writes = Array::new();
			for row in &self.writes {
				let pair = Array::new();
				pair.push(&Uint8Array::from(row.key.as_slice()));
				pair.push(
					&row.value
						.as_ref()
						.map_or(JsValue::UNDEFINED, |v| Uint8Array::from(v.as_slice()).into()),
				);
				writes.push(&pair);
			}
			output.push(&writes);
		}
		Ok(output.into())
	}
	pub fn context(&mut self) -> *mut c_void {
		(self as *mut Self).cast()
	}
}

/// The C evaluator keeps these borrows inside one synchronous call. Writes
/// append owned entries, so replacing a value cannot invalidate a prior borrow.
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
		2 => plan.put(key, None),
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
