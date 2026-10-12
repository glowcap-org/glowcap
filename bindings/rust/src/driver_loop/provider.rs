//! Consumer-facing transport package installation.

use super::*;
type InstallFuture = Pin<Box<dyn Future<Output = Result<()>>>>;

/// A configured transport package that can install itself into a native loop.
/// Transport modules construct this value. The driver registry alone records
/// which transport symbols the package registered.
#[derive(Clone)]
pub struct Provider {
	install: Rc<dyn Fn(Rc<LoopShared>) -> InstallFuture>,
}

impl Provider {
	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion", feature = "relay"))]
	pub(crate) fn new<F, Fut>(install: F) -> Self
	where
		F: Fn(Rc<LoopShared>) -> Fut + 'static,
		Fut: Future<Output = Result<()>> + 'static,
	{
		Self {
			install: Rc::new(move |lp| Box::pin(install(lp))),
		}
	}

	pub(crate) async fn install(&self, lp: Rc<LoopShared>) -> Result<()> {
		(self.install)(lp).await
	}
}
