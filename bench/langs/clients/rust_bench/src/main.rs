//! The Rust bench client for the per-language consumer-cost bench. It drives the
//! taskboard unit against the fixed Zig host through pancake's Rust binding (the
//! same connect/fetch/send the demos use) and prints one NDJSON metric line in
//! the shared schema (see bench/langs/contract.md). Being ahead-of-time compiled,
//! it needs no warmup and reports `warmup_n` of 0.
//!
//!   langs-bench <mode> <host> <port> <n>

use std::time::{Duration, Instant};

use pancake::{connect, tcp_locator, Argument, Connection, Ref};

const CLIENT: &str = "rust";
const RUNTIME: &str = "rust";

async fn run_unit(conn: &Connection, root: &Ref) -> Result<(), String> {
	let reply = conn
		.send(root, "create", &[Argument::Bytes(b"benchmark".to_vec())])
		.await
		.map_err(|e| format!("create: {e:?}"))?;
	let task =
		Ref::try_from(&reply).map_err(|_| "create did not return a capability".to_string())?;
	conn.send(&task, "assign", &[Argument::Bytes(b"alice".to_vec())])
		.await
		.map_err(|e| format!("assign: {e:?}"))?;
	conn.send(&task, "complete", &[])
		.await
		.map_err(|e| format!("complete: {e:?}"))?;
	let status = conn
		.send(&task, "status", &[])
		.await
		.map_err(|e| format!("status: {e:?}"))?;
	match status.as_bytes() {
		Some(b"done") => Ok(()),
		other => Err(format!("bad status: {other:?}")),
	}
}

// The same four verbs as `run_unit`, but pipelined (ADR-0007, questioner half):
// `assign`/`complete`/`status` are addressed at the answer `create` will resolve
// to — a `&RemotePromise` send target — without awaiting it, so the unit costs
// one round trip instead of four. Only the final `status` is awaited. The
// throughput unit; `run_unit` stays sequential so latency keeps measuring a
// single round trip.
async fn run_unit_pipelined(conn: &Connection, root: &Ref) -> Result<(), String> {
	let create = conn.send(root, "create", &[Argument::Bytes(b"benchmark".to_vec())]);
	let _assign = conn.send(&create, "assign", &[Argument::Bytes(b"alice".to_vec())]);
	let _complete = conn.send(&create, "complete", &[]);
	let status = conn
		.send(&create, "status", &[])
		.await
		.map_err(|e| format!("status: {e:?}"))?;
	match status.as_bytes() {
		Some(b"done") => Ok(()),
		other => Err(format!("bad status: {other:?}")),
	}
}

fn percentile_ms(sorted: &[f64], p: f64) -> f64 {
	if sorted.is_empty() {
		return 0.0;
	}
	let rank = (p * sorted.len() as f64).ceil() as usize;
	sorted[rank.saturating_sub(1).min(sorted.len() - 1)]
}

async fn run_latency(locator: &str, n: usize) -> Result<(), String> {
	let conn = connect(locator, None)
		.await
		.map_err(|e| format!("connect: {e:?}"))?;
	let root = conn
		.fetch("root")
		.await
		.map_err(|e| format!("fetch: {e:?}"))?;
	let mut lats: Vec<f64> = Vec::with_capacity(n);
	for _ in 0..n {
		let s = Instant::now();
		run_unit(&conn, &root).await?;
		lats.push(s.elapsed().as_secs_f64() * 1000.0);
	}
	conn.close();
	lats.sort_by(|a, b| a.partial_cmp(b).unwrap());
	let mean = if n == 0 {
		0.0
	} else {
		lats.iter().sum::<f64>() / n as f64
	};
	println!(
        "{{\"v\":1,\"metric\":\"latency\",\"client\":\"{CLIENT}\",\"suite\":\"taskboard\",\"n\":{n},\"p50_ms\":{:.4},\"p99_ms\":{:.4},\"p999_ms\":{:.4},\"mean_ms\":{:.4},\"runtime\":\"{RUNTIME}\",\"warmup_n\":0}}",
        percentile_ms(&lats, 0.50), percentile_ms(&lats, 0.99), percentile_ms(&lats, 0.999), mean,
    );
	Ok(())
}

async fn run_throughput(locator: &str, n: usize) -> Result<(), String> {
	let conn = connect(locator, None)
		.await
		.map_err(|e| format!("connect: {e:?}"))?;
	let root = conn
		.fetch("root")
		.await
		.map_err(|e| format!("fetch: {e:?}"))?;
	let t0 = Instant::now();
	for _ in 0..n {
		run_unit_pipelined(&conn, &root).await?;
	}
	let total = t0.elapsed().as_secs_f64() * 1000.0;
	conn.close();
	let rps = if total <= 0.0 {
		0.0
	} else {
		n as f64 / (total / 1000.0)
	};
	println!(
        "{{\"v\":1,\"metric\":\"throughput\",\"client\":\"{CLIENT}\",\"suite\":\"taskboard\",\"n\":{n},\"total_ms\":{:.2},\"rps\":{},\"runtime\":\"{RUNTIME}\",\"warmup_n\":0}}",
        total, rps.round() as i64,
    );
	Ok(())
}

async fn run_connections(locator: &str, n: usize) -> Result<(), String> {
	let mut warm: Vec<Connection> = Vec::new();
	for _ in 0..n.min(5) {
		let c = connect(locator, None)
			.await
			.map_err(|e| format!("connect: {e:?}"))?;
		c.fetch("root").await.map_err(|e| format!("fetch: {e:?}"))?;
		warm.push(c);
	}
	println!("{{\"v\":1,\"event\":\"warmed\"}}");
	tokio::time::sleep(Duration::from_millis(600)).await;
	let mut handles: Vec<Connection> = Vec::with_capacity(n);
	let t0 = Instant::now();
	for _ in 0..n {
		let c = connect(locator, None)
			.await
			.map_err(|e| format!("connect: {e:?}"))?;
		c.fetch("root").await.map_err(|e| format!("fetch: {e:?}"))?;
		handles.push(c);
	}
	let total = t0.elapsed().as_secs_f64() * 1000.0;
	println!(
        "{{\"v\":1,\"metric\":\"connections\",\"client\":\"{CLIENT}\",\"suite\":\"taskboard\",\"conns\":{n},\"total_ms\":{:.2},\"per_conn_ms\":{:.4},\"runtime\":\"{RUNTIME}\"}}",
        total, total / n.max(1) as f64,
    );
	tokio::time::sleep(Duration::from_millis(2500)).await;
	for c in handles {
		c.close();
	}
	for c in warm {
		c.close();
	}
	Ok(())
}

async fn run_cold(locator: &str) -> Result<(), String> {
	let conn = connect(locator, None)
		.await
		.map_err(|e| format!("connect: {e:?}"))?;
	let root = conn
		.fetch("root")
		.await
		.map_err(|e| format!("fetch: {e:?}"))?;
	run_unit(&conn, &root).await?;
	conn.close();
	println!("{{\"v\":1,\"event\":\"cold-done\",\"client\":\"{CLIENT}\"}}");
	Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
	let args: Vec<String> = std::env::args().collect();
	if args.len() < 4 {
		eprintln!("usage: langs-bench <mode> <host> <port> <n>");
		std::process::exit(2);
	}
	let mode = args[1].clone();
	let Ok(port) = args[3].parse::<u16>() else {
		eprintln!("port must be a number");
		std::process::exit(2);
	};
	let locator = tcp_locator(&args[2], port);
	let n: usize = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(0);

	let local = tokio::task::LocalSet::new();
	let result = local
		.run_until(async {
			match mode.as_str() {
				"latency" => run_latency(&locator, n).await,
				"throughput" => run_throughput(&locator, n).await,
				"connections" => run_connections(&locator, n).await,
				"cold" => run_cold(&locator).await,
				other => Err(format!("unknown mode: {other}")),
			}
		})
		.await;

	match result {
		Ok(()) => std::process::exit(0),
		Err(e) => {
			eprintln!("langs-bench failed: {e}");
			std::process::exit(1);
		}
	}
}
