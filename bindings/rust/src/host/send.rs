//! Application sends borrow no connection and observe the existing Host vows.
use super::*;
use crate::{Argument, Ref, SendArena};
use std::{future::IntoFuture, pin::Pin};

/// An await-only Host send. Its guard releases observation when dropped.
/// The core's existing producer owns admitted work independently.
pub struct HostPromise {
	admission: Result<u64>,
	host: Rc<HostShared>,
	release: Option<crate::gc::VowGuard>,
}
impl HostPromise {
	pub fn into_admitted(self) -> Result<Self> {
		match self.admission {
			Ok(_) => Ok(self),
			Err(error) => Err(error),
		}
	}
}
impl IntoFuture for HostPromise {
	type Output = Result<Argument>;
	type IntoFuture = Pin<Box<dyn Future<Output = Self::Output>>>;
	fn into_future(self) -> Self::IntoFuture {
		Box::pin(async move {
			let _release = self.release;
			let vow = self.admission?;
			self.host.observe_vow(vow).await
		})
	}
}
impl Host {
	/// Queue a notification at the held target's actual home. No reply vow is
	/// created. The queue owns admitted work independently of this handle.
	pub fn tell<'a>(&self, target: &Ref, verb: impl Into<Option<&'a str>>, args: &[Argument]) -> Result<()> {
		let verb = verb.into();
		self.shared.guard_handle()?;
		let target = target.to_sys()?;
		let mut arena = SendArena::for_host(&self.shared);
		let (args, count) = arena.build(args)?;
		// SAFETY: `self.shared.raw()` is the `GlowcapHost` handle owned by `HostShared`, proven non-null by
		// `guard_handle` above; `target` is a local `GlowcapReference` borrowed for the call, `verb` is a `&str`
		// borrowed for the call, and `args`/`count` come from `arena`, a live local `SendArena`; the header says the
		// host copies what it queues.
		arena.finish(check_host(unsafe {
			ffi::glowcap_host_tell(
				self.shared.raw(),
				&target,
				verb.map_or(core::ptr::null(), str::as_ptr),
				verb.map_or(0, str::len),
				args,
				count,
			)
		}))?;
		self.shared.schedule_kick()
	}
	/// Admit an eventual send using the target's actual local or foreign home.
	/// The Host queue copies borrowed arguments. Completion uses its usual action
	/// drain. Callbacks use their turn-scoped send so rollback remains atomic.
	pub fn send<'a>(&self, target: &Ref, verb: impl Into<Option<&'a str>>, args: &[Argument]) -> HostPromise {
		let verb = verb.into();
		let admission = (|| {
			self.shared.guard_handle()?;
			let target = target.to_sys()?;
			let mut arena = SendArena::for_host(&self.shared);
			let (args, count) = arena.build(args)?;
			let mut vow = 0;
			// SAFETY: as `tell` above, for `self.shared.raw()`, `target`, `verb`, and the `arena` views; `vow` is a
			// local out-parameter the callee fills.
			arena.finish(check_host(unsafe {
				ffi::glowcap_host_send(
					self.shared.raw(),
					&target,
					verb.map_or(core::ptr::null(), str::as_ptr),
					verb.map_or(0, str::len),
					args,
					count,
					&mut vow,
				)
			}))?;
			self.shared.owned_vow_minted(vow);
			if let Err(error) = self.shared.schedule_kick() {
				self.shared.settle_vow(vow, Err(error));
			}
			Ok(vow)
		})();
		HostPromise {
			release: admission
				.as_ref()
				.ok()
				.map(|&vow| crate::gc::VowGuard::new(&self.shared, vow)),
			admission,
			host: Rc::clone(&self.shared),
		}
	}
}
