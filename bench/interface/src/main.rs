//! Paired frontend cost over one negotiated Syrup / CapTP 1.0 TCP workflow.
//! Timing, allocator traffic, and trace observation are distinct runs.
#[allow(dead_code)]
#[cfg(feature = "generated-client")]
#[path = "../../../test/interface/generated/callbacks.rs"]
mod callbacks;
#[allow(dead_code)]
#[path = "../../../test/interface/rust/pair.rs"]
mod connection;
#[allow(dead_code)]
#[cfg(feature = "generated-client")]
#[path = "../../../apps/tasks/rust/interface.rs"]
mod creation;

#[cfg(not(any(feature = "raw-client", feature = "generated-client")))]
compile_error!("select at least one interface benchmark client");
#[cfg(all(
	feature = "allocation-metrics",
	not(all(feature = "raw-client", feature = "generated-client"))
))]
compile_error!("allocation diagnostics compare both clients");
mod meter;
mod peer;
mod wire;
mod workflow;

use meter::Meter;
#[cfg(feature = "allocation-metrics")]
use meter::RUST;
use peer::Pair;
use std::{
	ffi::CStr,
	sync::Arc,
	time::{Duration, Instant},
};
use workflow::{Client, Row};

#[global_allocator]
#[cfg(feature = "allocation-metrics")]
static ALLOCATOR: meter::RustAllocator = meter::RustAllocator;

struct Options {
	mode: String,
	samples: usize,
	pairs: usize,
	warmup: usize,
}
impl Options {
	fn read() -> Self {
		let mut options = Self {
			mode: if cfg!(feature = "allocation-metrics") {
				"diagnostics"
			} else {
				"latency"
			}
			.into(),
			samples: 100,
			pairs: 3,
			warmup: 20,
		};
		for argument in std::env::args().skip(1) {
			if argument == "--smoke" {
				options.samples = 2;
				options.pairs = 1;
				options.warmup = 1;
				continue;
			}
			let (key, value) = argument
				.split_once('=')
				.expect("expected --mode/--samples/--pairs/--warmup=value");
			match key {
				"--mode" => options.mode = value.into(),
				"--samples" => options.samples = value.parse().unwrap(),
				"--pairs" => options.pairs = value.parse().unwrap(),
				"--warmup" => options.warmup = value.parse().unwrap(),
				_ => panic!("unknown option"),
			}
		}
		assert!(matches!(options.mode.as_str(), "diagnostics" | "latency" | "profile"));
		assert_eq!(
			options.mode == "diagnostics",
			cfg!(feature = "allocation-metrics"),
			"diagnostic and ordinary allocator builds must remain separate"
		);
		assert!(
			(1..=100_000).contains(&options.samples) && (1..=20).contains(&options.pairs) && options.warmup <= 10_000
		);
		options
	}
}

async fn sample(pair: &Pair, client: Client, row: Row) {
	let request = workflow::setup(pair, client, row).await;
	let before = workflow::state(pair);
	let result = workflow::operation(pair, client, row, request.as_ref()).await;
	workflow::verify(pair, row, before, &result);
}

#[cfg(feature = "allocation-metrics")]
async fn diagnostic(client: Client, row: Row, warmup: usize) -> wire::Counts {
	let native = Arc::new(Meter::new());
	let pair = Pair::open(native.clone(), false).await;
	for _ in 0..warmup {
		sample(&pair, client, row).await;
	}
	let request = workflow::setup(&pair, client, row).await;
	let before = workflow::state(&pair);
	let rust_before = RUST.start();
	let native_before = native.start();
	let result = workflow::operation(&pair, client, row, request.as_ref()).await;
	let native_cost = native.stop(native_before);
	let rust_cost = RUST.stop(rust_before);
	workflow::verify(&pair, row, before, &result);
	println!(
		"interface_alloc client={} row={} native_scope=both_host_contexts rust_allocations={} rust_requested_bytes={} rust_live_delta={} native_allocations={} native_requested_bytes={} native_live_delta={}",
		client.name(),
		row.name(),
		rust_cost.allocations,
		rust_cost.requested,
		rust_cost.live,
		native_cost.allocations,
		native_cost.requested,
		native_cost.live
	);
	drop(result);
	drop(request);
	assert!(pair.close().await.is_none());

	// Frame observation buffers and forwards bytes. A fresh pair isolates this
	// scheduling and allocation cost from the allocation and timing passes.
	let pair = Pair::open(Arc::new(Meter::new()), true).await;
	for _ in 0..warmup {
		sample(&pair, client, row).await;
	}
	let request = workflow::setup(&pair, client, row).await;
	let before = workflow::state(&pair);
	pair.start_wire();
	let result = workflow::operation(&pair, client, row, request.as_ref()).await;
	workflow::verify(&pair, row, before, &result);
	let after = workflow::state(&pair);
	drop(result);
	drop(request);
	let wire = pair.close().await.unwrap();
	let frames = wire.frames;
	let bytes = wire.codec_bytes;
	assert!(frames > 0 && bytes > 0);
	println!(
		"interface_wire client={} row={} scope=operation_and_session_teardown outbound_frames={} codec_frame_bytes={} logical_calls={} committed_effects={}",
		client.name(),
		row.name(),
		frames,
		bytes,
		after.0 - before.0 + after.1 - before.1 + after.2 - before.2,
		after.3 - before.3
	);
	for (arm, count) in &wire.arms {
		println!(
			"interface_wire_arm client={} row={} arm={} count={}",
			client.name(),
			row.name(),
			arm,
			count
		);
	}
	wire
}

fn phase(client: Client, row: Row) -> &'static CStr {
	match (client.name(), row) {
		("raw", Row::Ordinary) => c"raw-ordinary",
		("generated", Row::Ordinary) => c"generated-ordinary",
		("raw", Row::Preparation) => c"raw-preparation",
		("generated", Row::Preparation) => c"generated-preparation",
		("raw", Row::Submission) => c"raw-submission",
		("generated", Row::Submission) => c"generated-submission",
		("raw", Row::Replay) => c"raw-replay",
		("generated", Row::Replay) => c"generated-replay",
		_ => unreachable!(),
	}
}

async fn timed(options: &Options, client: Client, row: Row, pair_index: usize) {
	let pair = Pair::open(Arc::new(Meter::new()), false).await;
	for _ in 0..options.warmup {
		sample(&pair, client, row).await;
	}
	let mut samples = Vec::with_capacity(options.samples);
	for _ in 0..options.samples {
		let request = workflow::setup(&pair, client, row).await;
		let before = workflow::state(&pair);
		if options.mode == "profile" {
			meter::begin();
		}
		let start = Instant::now();
		let result = workflow::operation(&pair, client, row, request.as_ref()).await;
		let ns = start.elapsed().as_nanos() as u64;
		if options.mode == "profile" {
			meter::end(phase(client, row));
		}
		workflow::verify(&pair, row, before, &result);
		samples.push(ns);
	}
	assert!(pair.close().await.is_none());
	if options.mode == "profile" {
		println!(
			"interface_profile client={} row={} calls={}",
			client.name(),
			row.name(),
			samples.len()
		);
		return;
	}
	samples.sort_unstable();
	let percentile = |p: usize| samples[(samples.len() * p).div_ceil(100).saturating_sub(1)];
	println!(
		"interface_latency client={} row={} pair={} calls={} warmup={} p50_ns={} p99_ns={} mean_ns={} mode={}",
		client.name(),
		row.name(),
		pair_index,
		samples.len(),
		options.warmup,
		percentile(50),
		percentile(99),
		samples.iter().sum::<u64>() / samples.len() as u64,
		options.mode
	);
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
	let options = Options::read();
	println!(
		"interface_environment transport=tcp address=127.0.0.1 profile=interop codec=syrup captp=1.0 runtime=current_thread snapshot_bytes={} total_copied_bytes=unmeasured",
		workflow::INPUT.len()
	);
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(
				Duration::from_secs(if options.mode == "profile" { 180 } else { 25 }),
				async {
					for row in Row::ALL {
						if options.mode == "diagnostics" {
							#[cfg(all(
								feature = "allocation-metrics",
								feature = "raw-client",
								feature = "generated-client"
							))]
							{
								let raw = diagnostic(Client::Raw, row, options.warmup).await;
								let generated = diagnostic(Client::Generated, row, options.warmup).await;
								assert_eq!(raw.frames, generated.frames, "generated call added wire frames");
								assert_eq!(raw.arms, generated.arms, "generated call changed protocol arm counts");
							}
						} else {
							for pair in 0..options.pairs {
								for index in 0..Client::ALL.len() {
									let index = if pair % 2 == 0 {
										index
									} else {
										Client::ALL.len() - 1 - index
									};
									timed(&options, Client::ALL[index], row, pair).await;
								}
							}
						}
					}
				},
			)
			.await
			.expect("interface benchmark exceeded bounded workload deadline");
		})
		.await;
}
