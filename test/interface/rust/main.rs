//! Rust qualification runner for Tasks creation, refusals, and callbacks.
#[path = "../generated/callbacks.rs"]
pub mod callbacks;
#[path = "../generated/compounds.rs"]
pub mod compound_generated;
mod compounds;
mod conversation;
#[path = "../generated/expected.rs"]
mod expected;
#[path = "../../../apps/tasks/rust/interface.rs"]
pub mod interface;
mod invocation;
mod observations;
mod pair;
mod prepared;
mod presence;
mod reads;
mod receipt_ownership;
mod receipts;
#[path = "../generated/scalars.rs"]
pub mod scalar_generated;
mod scalars;
#[path = "../../../apps/tasks/rust/board.rs"]
pub mod task_board;
mod tasks;

#[tokio::main(flavor = "current_thread")]
async fn main() {
	let args: Vec<String> = std::env::args().collect();
	assert_eq!(args.len(), 3, "expected locator and board name");
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(std::time::Duration::from_secs(15), async {
				tasks::run(&glowcap::parse_locator(&args[1]).unwrap(), &args[2]).await;
				reads::run().await;
				observations::run().await;
				compounds::run().await;
				scalars::run().await;
				conversation::run().await;
				invocation::run().await;
				presence::run().await;
				prepared::run().await;
				receipts::run().await;
				receipt_ownership::run().await;
			})
			.await
			.expect("interface conversation proof timed out");
		})
		.await;
}
