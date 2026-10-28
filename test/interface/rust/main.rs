//! Rust qualification runner for Tasks creation, refusals, and callbacks.
#[path = "../generated/callbacks.rs"]
pub mod callbacks;
mod conversation;
mod tasks;

#[tokio::main(flavor = "current_thread")]
async fn main() {
	let args: Vec<String> = std::env::args().collect();
	assert_eq!(args.len(), 3, "expected port and board name");
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(std::time::Duration::from_secs(15), async {
				tasks::run(args[1].parse().unwrap(), &args[2]).await;
				conversation::run().await;
			})
			.await
			.expect("interface conversation proof timed out");
		})
		.await;
}
