//! The gate an iroh example passes: it takes no port argument, and it serves
//! every session its proof server accepts until the local task set ends.
//! Each example compiles its own copy through `#[path]` and uses the part its
//! proof needs, so the unused rest is expected.
#![allow(dead_code)]

use std::rc::Rc;

pub type Fail = Box<dyn std::error::Error>;

pub fn ignore_port_args() -> Result<(), Fail> {
	for arg in std::env::args().skip(1) {
		if !arg.starts_with("--port=") {
			return Err(format!("unknown argument '{arg}'").into());
		}
	}
	Ok(())
}

/// Serve every iroh session a proof server accepts for the life of its local
/// task set. The owning session handle stays in the serve task, retaining an
/// accepted handle without serving it leaves published objects reachable in
/// name but unable to answer.
pub fn serve_iroh_sessions(server: Rc<glowcap::iroh::Server>) {
	tokio::task::spawn_local(async move {
		while let Ok(session) = server.accept().await {
			tokio::task::spawn_local(async move {
				let _ = session.serve().await;
			});
		}
	});
}
