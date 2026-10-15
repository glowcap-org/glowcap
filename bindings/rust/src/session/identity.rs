use super::Session;
use crate::host::check_host;
use crate::sys;
use crate::sys::host as ffi;
use crate::{Error, Result};

/// Who the partner on a session proved itself to be, as
/// [`Session::partner_identity`] returns it.
///
/// Every field is copied out of the session at the call, so the values outlive
/// the session that produced them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PartnerIdentity {
	/// The partner's session public key, the one thing its handshake signature
	/// is made with. Always present.
	pub session_key: Vec<u8>,
	/// The location designator the partner signed, such as a hex key for
	/// `keyed-tcp` or a `host:port` for `tcp`. Empty when the partner's
	/// location carried no designator.
	pub designator: String,
	/// The verbatim `<ocapn-peer>` record the key and designator were read
	/// from, which is the span the signature covers. Empty when the session
	/// captured no record.
	pub locator_record: Vec<u8>,
	/// How the durable identity in `designator` was authenticated, if at all.
	/// Session identity, durable identity, and this provenance are three
	/// separate facts (ADR-0097): ask
	/// [`durable_identity_authenticated`](PartnerIdentity::durable_identity_authenticated)
	/// for a proved durable peer, never whether `designator` equals
	/// `session_key`.
	pub provenance: DurableProvenance,
}

/// How a partner's advertised durable identity was authenticated, the third
/// fact [`PartnerIdentity`] reports beside session key and designator.
///
/// The answer is a property of the connection rather than of its transport name
/// (ADR-0105): the same transport symbol reaches this peer over code that can
/// prove something and code that cannot, so no list of transports belongs here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DurableProvenance {
	/// The code that realized this connection verified the far end of the byte
	/// channel holds a durable key, and the partner claimed that same key.
	AuthenticatedTransport,
	/// No durable identity was proved. An address transport designates a socket
	/// address rather than a key, and a partner that advertised an address on a
	/// key transport claimed no durable identity to authenticate.
	Unauthenticated,
}

impl DurableProvenance {
	/// One ABI provenance value in its spoken form.
	///
	/// Two surfaces report the same provenance fact about the same partner,
	/// this identity query and the live trace's session-open, so the mapping
	/// lives here once rather than being spelled at each of them.
	pub(crate) fn from_abi(raw: u32) -> Result<Self> {
		match raw {
			sys::DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT => Ok(Self::AuthenticatedTransport),
			sys::DURABLE_PROVENANCE_UNAUTHENTICATED => Ok(Self::Unauthenticated),
			other => Err(Error::with_detail(
				sys::ERR_INTERNAL,
				format!("glowcap ABI returned unknown durable provenance {other}"),
			)),
		}
	}
}

impl PartnerIdentity {
	/// Whether the durable identity this partner advertised was
	/// cryptographically authenticated by the realized channel. This is the
	/// predicate to ask when an operation requires a proved durable peer. It
	/// stays correct once each session draws a fresh signing key.
	pub fn durable_identity_authenticated(&self) -> bool {
		self.provenance != DurableProvenance::Unauthenticated
	}
}

impl Session {
	/// Compare the actual local connection shared by two handles, including
	/// callback views. Equal partner identities do not imply equal sessions.
	pub fn same_session(&self, other: &Self) -> bool {
		std::rc::Rc::ptr_eq(&self.shared, &other.shared)
	}

	/// Who this session's partner proved itself to be during the handshake.
	///
	/// A partner's keyed `op:start-session` carries an Ed25519 signature over
	/// its own location record, and the engine verifies that signature before
	/// the session opens. So a success here always means the signature was
	/// checked. The signed span binds the whole locator claim to the fresh
	/// [`session_key`](PartnerIdentity::session_key). It does not prove control
	/// of the durable [`designator`](PartnerIdentity::designator). Read
	/// [`provenance`](PartnerIdentity::provenance) before relying on a durable
	/// identity.
	///
	/// The bytes are copied out of the session here, so the returned
	/// [`PartnerIdentity`] stays valid after the session closes.
	///
	/// Two refusals are ordinary rather than faults. Before the partner's
	/// `op:start-session` has arrived with a key there is nothing to report
	/// yet, and a session opened without partner verification has no proved
	/// identity at all.
	pub fn partner_identity(&self) -> Result<PartnerIdentity> {
		self.shared.guard_open()?;
		let mut out = ffi::GlowcapPartnerIdentity {
			session_key: core::ptr::null(),
			session_key_len: 0,
			designator: core::ptr::null(),
			designator_len: 0,
			locator_record: core::ptr::null(),
			locator_record_len: 0,
			provenance: sys::DURABLE_PROVENANCE_UNAUTHENTICATED,
		};
		// SAFETY: `self.shared.ptr` is this session's `GlowcapHostSession` handle, owned by the Host and nulled only
		// when the session is released, and `guard_open` above proved it live; `out` is a local
		// `GlowcapPartnerIdentity` the callee fills.
		check_host(unsafe { ffi::glowcap_host_session_partner_identity(self.shared.ptr.get(), &mut out) })?;
		// Session-owned views, valid only until the session is released, so
		// every field is copied before it leaves this call.
		// SAFETY: after the OK return `check_host` verified, the callee has filled `out` with views into the session's
		// retained identity, valid until the session is released; `self.shared` is not released while `&self` is
		// borrowed, and `owned_from_view` copies each view before the block ends.
		let (session_key, designator, locator_record) = unsafe {
			(
				crate::owned_from_view(out.session_key, out.session_key_len),
				crate::owned_from_view(out.designator, out.designator_len),
				crate::owned_from_view(out.locator_record, out.locator_record_len),
			)
		};
		let provenance = DurableProvenance::from_abi(out.provenance)?;
		Ok(PartnerIdentity {
			session_key,
			designator: String::from_utf8_lossy(&designator).into_owned(),
			locator_record,
			provenance,
		})
	}

	/// Testify what proved this connection's far end, when your own transport
	/// proved one.
	///
	/// glowcap does not open your sockets, so it cannot see what opening them
	/// established. An iroh connection completes only with the holder of the
	/// node id you dialed or accepted, and that is a stronger fact than
	/// anything a partner can claim about itself, but only you hold it. Pass
	/// the node id here and [`partner_identity`](Session::partner_identity)
	/// reports `AuthenticatedTransport`. Withhold it and the same session
	/// reports `Unauthenticated`.
	///
	/// `designator` is that identity as a locator writes it, which is exactly
	/// what the iroh transport's remote node id hands you.
	///
	/// Call it after opening the session and before feeding the first byte from
	/// the partner. It fails afterwards, because by then the handshake this
	/// evidence was for has already been judged. Naming a second, different
	/// identity fails too: one connection has one far end. Naming the same one
	/// twice is the same statement made twice and succeeds.
	pub fn bind_verified_channel_key(&self, designator: &str) -> Result<()> {
		self.shared.guard_open()?;
		// SAFETY: `self.shared.ptr` is this session's live `GlowcapHostSession` handle (`guard_open` above);
		// `designator` is a `&str` borrowed for the call, which the callee reads only during it.
		check_host(unsafe {
			ffi::glowcap_host_session_bind_verified_channel_key(
				self.shared.ptr.get(),
				designator.as_ptr(),
				designator.len(),
			)
		})?;
		Ok(())
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn unknown_ffi_provenance_is_a_returned_failure() {
		let error = DurableProvenance::from_abi(u32::MAX).unwrap_err();
		assert_eq!(error.kind(), crate::ErrorKind::Internal);
	}
}
