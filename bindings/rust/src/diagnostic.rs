//! Structured failures that had no remaining deterministic return recipient.

use crate::{Error, Result, abi_constants_gen, sys};

/// The layer that observed an unreturnable failure.
#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureLayer {
	Core,
	Driver,
	Transport,
	Binding,
	ApplicationObserver,
}

impl FailureLayer {
	pub(crate) fn from_abi(value: u32) -> Result<Self> {
		match value {
			abi_constants_gen::FAILURE_LAYER_CORE => Ok(Self::Core),
			abi_constants_gen::FAILURE_LAYER_DRIVER => Ok(Self::Driver),
			abi_constants_gen::FAILURE_LAYER_TRANSPORT => Ok(Self::Transport),
			abi_constants_gen::FAILURE_LAYER_BINDING => Ok(Self::Binding),
			abi_constants_gen::FAILURE_LAYER_APPLICATION_OBSERVER => Ok(Self::ApplicationObserver),
			other => Err(Error::with_detail(
				sys::ERR_INTERNAL,
				format!("glowcap ABI returned unknown failure layer {other}"),
			)),
		}
	}
}

/// The lifecycle owner whose operation produced an unreturnable failure.
#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureScope {
	Process,
	Context,
	Host,
	Session,
	Listener,
	Transport,
	Operation,
}

impl FailureScope {
	pub(crate) fn from_abi(value: u32) -> Result<Self> {
		match value {
			abi_constants_gen::FAILURE_SCOPE_PROCESS => Ok(Self::Process),
			abi_constants_gen::FAILURE_SCOPE_CONTEXT => Ok(Self::Context),
			abi_constants_gen::FAILURE_SCOPE_HOST => Ok(Self::Host),
			abi_constants_gen::FAILURE_SCOPE_SESSION => Ok(Self::Session),
			abi_constants_gen::FAILURE_SCOPE_LISTENER => Ok(Self::Listener),
			abi_constants_gen::FAILURE_SCOPE_TRANSPORT => Ok(Self::Transport),
			abi_constants_gen::FAILURE_SCOPE_OPERATION => Ok(Self::Operation),
			other => Err(Error::with_detail(
				sys::ERR_INTERNAL,
				format!("glowcap ABI returned unknown failure scope {other}"),
			)),
		}
	}
}

/// One failure that had no remaining deterministic return recipient.
///
/// Context diagnostics are an ordered, bounded audit trail. They do not
/// duplicate failures returned by an API, raised by a callback owner, or held
/// by a close barrier. `dropped_before` reports records evicted before this
/// claim; `secondary_count` preserves the number of consequences while the
/// first consequence remains typed in `secondary_*`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FailureEvent {
	pub sequence: u64,
	pub dropped_before: u64,
	pub layer: FailureLayer,
	pub scope: FailureScope,
	pub scope_id: u64,
	pub operation_id: u64,
	pub primary_result: i32,
	pub secondary_result: i32,
	pub secondary_count: u32,
	pub truncated_fields: u32,
	pub operation: String,
	pub primary_name: String,
	pub primary_message: String,
	pub secondary_name: String,
	pub secondary_message: String,
}
