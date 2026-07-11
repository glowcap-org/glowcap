//! Shared LocalSet + timeout wrapper for Rust demo clients.

use std::time::Duration;

pub async fn run_with_timeout<F, T>(nick: &str, seconds: u64, fut: F) -> Result<T, String>
where
	F: std::future::Future<Output = Result<T, String>>,
{
	let local = tokio::task::LocalSet::new();
	local
		.run_until(async {
			match tokio::time::timeout(Duration::from_secs(seconds), fut).await {
				Ok(inner) => inner,
				Err(_) => Err(format!("{nick} timed out")),
			}
		})
		.await
}

pub fn exit_on_result(nick: &str, kind: &str, result: Result<(), String>) -> ! {
	match result {
		Ok(()) => std::process::exit(0),
		Err(err) => {
			eprintln!("{kind} {nick} failed: {err}");
			std::process::exit(1);
		}
	}
}
