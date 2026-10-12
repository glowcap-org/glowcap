//! Ordinary actor hosting needs a Host, with no transport or publication.
use super::*;
impl Host {
	/// Spawn an ordinary actor. The returned reference owns its local root.
	/// Final drop releases it while exports retain their independent roots.
	/// Turn-time factories use the existing turn spawn transaction.
	pub fn spawn(
		&self,
		behavior: impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static,
	) -> Result<Ref> {
		let turn = current_turn_for(Rc::as_ptr(&self.shared) as usize);
		if turn.is_none() {
			self.shared.guard_handle()?;
		}
		let cell = self.shared.actor_cell(outcome_behavior(behavior))?;
		let id = match turn {
			Some(turn) => crate::trampoline::turn_spawn(turn, cell)?,
			None => {
				let mut reference = sys::GlowcapReference { id: 0 };
				// SAFETY: `cell` is the fresh unregistered `ActorCell` that `HostShared::actor_cell` boxed, so nothing
				// else holds it; the closure makes the one `glowcap_host_spawn` call on `self.shared.raw()`, the Host
				// handle owned by `HostShared` and proven non-null by `guard_handle` above, and the host's single
				// thread runs no other access to the cell during it. `trampoline` and `ctx_free` are the binding's
				// callbacks for an `ActorCell`, and `reference` is a local out-parameter the callee writes.
				unsafe {
					register_actor_cell(
						cell,
						|| {
							ffi::glowcap_host_spawn(
								self.shared.raw(),
								trampoline,
								cell as *mut core::ffi::c_void,
								ctx_free,
								&mut reference,
							)
						},
						|code| code == sys::OK,
					)?;
				}
				reference.id
			}
		};
		let mut reference = Ref::bare_id(id);
		reference.attach_guard(crate::gc::owned_guard(&self.shared, id));
		Ok(reference)
	}
}
