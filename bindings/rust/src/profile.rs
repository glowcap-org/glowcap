//! Codec, CapTP-version, and feature negotiation projected into Rust types.

use crate::sys;
#[cfg(feature = "async")]
use crate::{Error, Result};

/// The wire codec a host's sessions speak and a TCP connection frames with. Both
/// ends of a connection must use the same value.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Codec {
	Syrup,
	Capnp,
}

impl Codec {
	#[cfg(feature = "async")]
	pub(crate) fn from_c(raw: u32) -> Result<Self> {
		match raw {
			sys::CODEC_SYRUP => Ok(Codec::Syrup),
			sys::CODEC_CAPNP => Ok(Codec::Capnp),
			other => Err(Error::with_detail(
				sys::ERR_INTERNAL,
				format!("pancake ABI returned unknown session codec {other}"),
			)),
		}
	}

	#[cfg(any(feature = "async", feature = "tcp", feature = "inproc", feature = "onion"))]
	pub(crate) fn to_c(self) -> u32 {
		match self {
			Codec::Syrup => sys::CODEC_SYRUP,
			Codec::Capnp => sys::CODEC_CAPNP,
		}
	}
}

impl Default for Codec {
	fn default() -> Self {
		match sys::DEFAULT_CODEC {
			sys::CODEC_SYRUP => Codec::Syrup,
			sys::CODEC_CAPNP => Codec::Capnp,
			_ => unreachable!("generated default codec must be a known PANCAKE_CODEC_* value"),
		}
	}
}

/// The CapTP profile a session speaks (ADR-0003). `V1_0` is the interop floor a
/// Goblins vat and the upstream suite speak; `Next` is the pancake-to-pancake
/// track that `Offer::native` prefers together with Cap'n Proto. A Host states
/// its preference in signed locator hints; each session settles the pair with
/// its partner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptpVersion {
	V1_0,
	Next,
}

impl CaptpVersion {
	#[cfg(feature = "async")]
	pub(crate) fn from_c(raw: u32) -> Result<Self> {
		match raw {
			sys::CAPTP_V1_0 => Ok(CaptpVersion::V1_0),
			sys::CAPTP_NEXT => Ok(CaptpVersion::Next),
			other => Err(Error::with_detail(
				sys::ERR_INTERNAL,
				format!("pancake ABI returned unknown session CapTP version {other}"),
			)),
		}
	}

	pub(crate) fn to_c(self) -> u32 {
		match self {
			CaptpVersion::V1_0 => sys::CAPTP_V1_0,
			CaptpVersion::Next => sys::CAPTP_NEXT,
		}
	}
}

impl Default for CaptpVersion {
	fn default() -> Self {
		match sys::DEFAULT_CAPTP_VERSION {
			sys::CAPTP_V1_0 => CaptpVersion::V1_0,
			sys::CAPTP_NEXT => CaptpVersion::Next,
			_ => unreachable!("generated default CapTP version must be a known PANCAKE_CAPTP_* value"),
		}
	}
}

/// Optional CapTP features a Host advertises during profile negotiation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FeatureSet(u32);

/// The profile a live session settled with its partner. `features` is the
/// exact mutually supported set, not the Host's offer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionProfile {
	pub captp_version: CaptpVersion,
	pub codec: Codec,
	pub features: FeatureSet,
}

impl FeatureSet {
	pub const MINIMUM: FeatureSet = FeatureSet(sys::FEATURE_MINIMUM);
	pub const BASELINE: FeatureSet = FeatureSet(sys::FEATURE_BASELINE);
	pub const PIPELINING: FeatureSet = FeatureSet(sys::FEATURE_PIPELINING);
	pub const HANDOFF: FeatureSet = FeatureSet(sys::FEATURE_HANDOFF);
	pub const WIRE_DELTA: FeatureSet = FeatureSet(sys::FEATURE_WIRE_DELTA);
	pub const STURDYREF: FeatureSet = FeatureSet(sys::FEATURE_STURDYREF);
	pub const UNTAG: FeatureSet = FeatureSet(sys::FEATURE_UNTAG);
	pub const MULTI_LOCATION: FeatureSet = FeatureSet(sys::FEATURE_MULTI_LOCATION);
	pub const FULL: FeatureSet = FeatureSet(sys::FEATURE_FULL);

	pub const fn from_bits(bits: u32) -> Option<FeatureSet> {
		if bits & !sys::FEATURE_FULL == 0 {
			Some(FeatureSet(bits))
		} else {
			None
		}
	}

	pub const fn bits(self) -> u32 {
		self.0
	}

	pub const fn contains(self, feature: FeatureSet) -> bool {
		(self.0 & feature.0) == feature.0
	}

	#[cfg(feature = "async")]
	pub(crate) const fn to_c(self) -> u32 {
		self.0
	}
}

impl core::ops::BitOr for FeatureSet {
	type Output = FeatureSet;

	fn bitor(self, rhs: FeatureSet) -> FeatureSet {
		FeatureSet(self.0 | rhs.0)
	}
}

impl core::ops::BitOrAssign for FeatureSet {
	fn bitor_assign(&mut self, rhs: FeatureSet) {
		self.0 |= rhs.0;
	}
}

impl Default for FeatureSet {
	fn default() -> Self {
		FeatureSet(sys::DEFAULT_FEATURES)
	}
}
