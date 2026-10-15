//! Three bounded input slots bridge asynchronous IndexedDB reads to Zig: the
//! cached metadata row, the one supplied row, and the one walked row of a
//! collection cursor. Writes copy directly to JavaScript and enter the same
//! active transaction, so no Rust overlay or transaction-sized snapshot exists.
use super::super::{check, invalid};
use crate::{Result, sys::loam as ffi};
use core::ffi::c_void;
use js_sys::{Array, Uint8Array};
use std::{cell::RefCell, rc::Rc};
use wasm_bindgen::{JsCast, JsValue};

const MAX_KEY_BYTES: usize = ffi::GLOWCAP_LOAM_MAX_KEY_BYTES;
/// Cumulative adapter costs. Input includes fixed Plan state and owned row/key
/// bytes. Submitted writes exclude IndexedDB's own cloning and reclamation.
///
/// `js_calls` and `callbacks` count the JavaScript/Wasm boundary at the adapter
/// shim in `storage.js`. `js_calls` counts each call from Rust into the shim:
/// opening the database, starting a transaction, queuing one write, checking
/// quiescence and closing. `callbacks` counts each entry from JavaScript into
/// Rust: one per planning step (the continuation that runs after each read
/// request or cursor step answers) and one per settled promise Rust awaits
/// (database open, transaction terminal event, close). The shim issues each
/// IndexedDB get and cursor request itself, so those requests are not
/// crossings. Each one is visible as the planning pass that answers it.
#[derive(Clone, Copy, Debug, Default)]
pub struct StorageStatistics {
	pub js_calls: u64,
	pub callbacks: u64,
	pub transactions: u64,
	pub planning_passes: u64,
	pub database_rows: u64,
	pub emitted_writes: u64,
	pub cursor_reads: u64,
	pub copied_bytes: u64,
	pub peak_input_bytes: usize,
	pub input_capacity_bytes: usize,
	pub max_transaction_write_bytes: usize,
}
impl StorageStatistics {
	/// The one place a call from Rust into the JavaScript shim is counted.
	pub(super) fn count_js_call(&mut self) {
		self.js_calls = self.js_calls.saturating_add(1);
	}
	/// The one place an entry from JavaScript into Rust is counted.
	pub(super) fn count_callback(&mut self) {
		self.callbacks = self.callbacks.saturating_add(1);
	}
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
/// The one request the transaction is suspended on.
enum Pending {
	Row(Vec<u8>),
	Cursor { prefix: Vec<u8>, after: Option<Vec<u8>> },
}
/// One answered walk step. `answer: None` means no key lay in range.
struct Cursor {
	prefix: Vec<u8>,
	after: Option<Vec<u8>>,
	answer: Option<Row>,
}
impl Cursor {
	fn bytes(&self) -> usize {
		self.prefix.len() + self.after.as_ref().map_or(0, Vec::len) + self.answer.as_ref().map_or(0, Row::bytes)
	}
}
pub(super) struct Plan {
	metadata: Option<Row>,
	row: Option<Row>,
	cursor: Option<Cursor>,
	pending: Option<Pending>,
	failure: Option<crate::Error>,
	rows: JsValue,
	write: bool,
	row_limit: usize,
	write_bytes: usize,
	statistics: Rc<RefCell<StorageStatistics>>,
}
impl Plan {
	pub fn input_capacity(row_limit: usize) -> Result<usize> {
		// Metadata key/value, one row key/value, one missing key, and one
		// cursor walk (prefix, floor, and the answered row) coexist.
		row_limit
			.checked_mul(2)
			.and_then(|rows| {
				rows.checked_add(core::mem::size_of::<Self>() + ffi::GLOWCAP_LOAM_METADATA_SIZE + 1 + 5 * MAX_KEY_BYTES)
			})
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
			cursor: None,
			pending: None,
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
			+ self.cursor.as_ref().map_or(0, Cursor::bytes)
			+ match &self.pending {
				None => 0,
				Some(Pending::Row(key)) => key.len(),
				Some(Pending::Cursor { prefix, after }) => prefix.len() + after.as_ref().map_or(0, Vec::len),
			}
	}
	pub fn input(&mut self, rows: JsValue, key: JsValue, value: JsValue) -> Result<()> {
		self.rows = rows;
		self.pending = None;
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
	/// Accept the key and value that the pending cursor request found, or
	/// neither when no key lay in range. The answer must honor the request.
	pub fn input_cursor(&mut self, rows: JsValue, key: JsValue, value: JsValue) -> Result<()> {
		self.rows = rows;
		self.failure = None;
		let Some(Pending::Cursor { prefix, after }) = self.pending.take() else {
			return Err(invalid("Loam cursor answer without a pending cursor"));
		};
		{
			let mut statistics = self.statistics.borrow_mut();
			statistics.planning_passes = statistics.planning_passes.saturating_add(1);
			statistics.cursor_reads = statistics.cursor_reads.saturating_add(1);
		}
		let answer = if key.is_undefined() && value.is_undefined() {
			None
		} else {
			if !key.is_instance_of::<Uint8Array>() || !value.is_instance_of::<Uint8Array>() {
				return Err(invalid("IndexedDB Loam row is not a byte array"));
			}
			let key = key.unchecked_into::<Uint8Array>();
			let value = value.unchecked_into::<Uint8Array>();
			if key.length() == 0 || key.length() as usize > MAX_KEY_BYTES {
				return Err(invalid("invalid Loam physical key"));
			}
			if value.length() as usize > self.row_limit {
				return Err(invalid("Loam transaction input row budget exceeded"));
			}
			let key = key.to_vec();
			if !key.starts_with(&prefix) || after.as_ref().is_some_and(|after| key <= *after) {
				return Err(invalid("IndexedDB Loam cursor row is outside the requested range"));
			}
			Some(Row {
				key,
				value: Some(value.to_vec()),
			})
		};
		let charged = answer.as_ref().map_or(0, Row::bytes);
		self.cursor = Some(Cursor { prefix, after, answer });
		let mut statistics = self.statistics.borrow_mut();
		if charged != 0 {
			statistics.database_rows = statistics.database_rows.saturating_add(1);
		}
		statistics.copied_bytes = statistics.copied_bytes.saturating_add(charged as u64);
		statistics.peak_input_bytes = statistics.peak_input_bytes.max(self.input_bytes());
		Ok(())
	}
	/// The first key under `prefix` and strictly after `after`, from the answered
	/// walk when it matches, else a suspension for JavaScript's cursor.
	pub fn next(&mut self, prefix: &[u8], after: Option<&[u8]>) -> Result<Option<&[u8]>> {
		if prefix.len() > MAX_KEY_BYTES || after.is_some_and(|after| after.len() > MAX_KEY_BYTES) {
			return Err(invalid("invalid Loam physical key"));
		}
		let hit = self
			.cursor
			.as_ref()
			.is_some_and(|cursor| cursor.prefix == prefix && cursor.after.as_deref() == after);
		if hit {
			return Ok(self
				.cursor
				.as_ref()
				.and_then(|cursor| cursor.answer.as_ref())
				.map(|row| row.key.as_slice()));
		}
		// The core reads a walked key before its next step, so a stale walk is spent.
		self.cursor = None;
		self.pending = Some(Pending::Cursor {
			prefix: prefix.to_vec(),
			after: after.map(<[u8]>::to_vec),
		});
		let charged = prefix.len() + after.map_or(0, <[u8]>::len);
		let mut statistics = self.statistics.borrow_mut();
		statistics.copied_bytes = statistics.copied_bytes.saturating_add(charged as u64);
		statistics.peak_input_bytes = statistics.peak_input_bytes.max(self.input_bytes());
		Err(crate::Error::with_detail(
			crate::sys::WOULD_BLOCK,
			"transaction cursor is not loaded".into(),
		))
	}
	pub fn get(&mut self, key: &[u8]) -> Result<Option<&[u8]>> {
		let walked = self.cursor.iter().filter_map(|cursor| cursor.answer.as_ref());
		if let Some(row) = self
			.metadata
			.iter()
			.chain(self.row.iter())
			.chain(walked)
			.find(|row| row.key == key)
		{
			return Ok(row.value.as_deref());
		}
		if key.is_empty() || key.len() > MAX_KEY_BYTES {
			return Err(invalid("invalid Loam physical key"));
		}
		self.pending = Some(Pending::Row(key.to_vec()));
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
		{
			// A write is counted where it crosses into JavaScript.
			let mut statistics = self.statistics.borrow_mut();
			statistics.emitted_writes = statistics.emitted_writes.saturating_add(1);
			statistics.count_js_call();
		}
		let js_key = Uint8Array::from(key);
		let js_value = value.map(|v| Uint8Array::from(v));
		super::js_put(&self.rows, &js_key, js_value.as_ref()).map_err(super::js_error)?;
		if self.metadata.as_ref().is_some_and(|row| row.key == key) {
			self.metadata = None;
		}
		if self.row.as_ref().is_some_and(|row| row.key == key) {
			self.row = None;
		}
		// A write under the prefix can change which key is next.
		if self
			.cursor
			.as_ref()
			.is_some_and(|cursor| key.starts_with(&cursor.prefix))
		{
			self.cursor = None;
		}
		self.write_bytes = total;
		let mut statistics = self.statistics.borrow_mut();
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
			let pending = self
				.pending
				.as_ref()
				.ok_or_else(|| invalid("planner suspended without a pending request"))?;
			let mut statistics = self.statistics.borrow_mut();
			match pending {
				Pending::Row(key) => {
					statistics.copied_bytes = statistics.copied_bytes.saturating_add(key.len() as u64);
					output.push(&0.into());
					output.push(&Uint8Array::from(key.as_slice()));
				}
				Pending::Cursor { prefix, after } => {
					let charged = prefix.len() + after.as_ref().map_or(0, Vec::len);
					statistics.copied_bytes = statistics.copied_bytes.saturating_add(charged as u64);
					output.push(&2.into());
					output.push(&Uint8Array::from(prefix.as_slice()));
					output.push(
						&after
							.as_ref()
							.map_or(JsValue::UNDEFINED, |after| Uint8Array::from(after.as_slice()).into()),
					);
				}
			}
		} else {
			if let Err(error) = check(code) {
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
		3 => {
			let floor = unsafe { &*value };
			let floor = (floor.present == 1).then(|| {
				if floor.len == 0 {
					&[][..]
				} else {
					unsafe { core::slice::from_raw_parts(floor.data, floor.len) }
				}
			});
			plan.next(key, floor).map(|next| unsafe {
				*out = ffi::GlowcapLoamBytes {
					data: next.map_or(core::ptr::null(), |v| v.as_ptr()),
					len: next.map_or(0, |v| v.len()),
					present: u32::from(next.is_some()),
				};
			})
		}
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
