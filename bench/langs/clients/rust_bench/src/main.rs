//! The Rust bench client for the per-language consumer-cost bench. It drives the
//! taskboard unit against the fixed Zig host through glowcap's Rust binding (the
//! same connect/fetch/send the demos use) and prints one NDJSON metric line in
//! the shared schema (see bench/langs/contract.md). Being ahead-of-time compiled,
//! it needs no warmup and reports `warmup_n` of 0.
//!
//!   langs-bench <mode> <host> <port> <n>

use std::time::{Duration, Instant};

use glowcap::{tcp, Argument, ConnectOptions, Locator, PendingWork, Ref, Runtime, RuntimeConfig, Session};

const CLIENT: &str = "rust";
const RUNTIME: &str = "rust";

async fn open_runtime() -> Result<Runtime, String> {
	Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.map_err(|e| format!("runtime: {e:?}"))
}

async fn open_held_connection(locator: &Locator) -> Result<(Runtime, Session), String> {
	let runtime = open_runtime().await?;
	let conn = match runtime.connect(locator, ConnectOptions::default()).await {
		Ok(conn) => conn,
		Err(error) => {
			let _ = runtime.close(PendingWork::Cancel).await;
			return Err(format!("connect: {error:?}"));
		}
	};
	drop(conn.serve());
	if let Err(error) = conn.fetch("root").await {
		let _ = conn.close(PendingWork::Cancel).await;
		let _ = runtime.close(PendingWork::Cancel).await;
		return Err(format!("fetch: {error:?}"));
	}
	Ok((runtime, conn))
}

async fn close_held_connection(runtime: Runtime, conn: Session) -> Result<(), String> {
	conn.close(PendingWork::Cancel)
		.await
		.map_err(|e| format!("close session: {e:?}"))?;
	runtime
		.close(PendingWork::Cancel)
		.await
		.map_err(|e| format!("close runtime: {e:?}"))
}

async fn run_unit(conn: &Session, root: &Ref) -> Result<(), String> {
	let reply = conn
		.send(root, "create", &[Argument::Bytes(b"benchmark".to_vec())])
		.await
		.map_err(|e| format!("create: {e:?}"))?;
	let task = Ref::try_from(&reply).map_err(|_| "create did not return a capability".to_string())?;
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
// to through a `&RemotePromise` target. `assign` and `complete` are one-way;
// only `status` allocates an answer and is awaited. The unit costs one round
// trip without leaving discarded result promises behind.
async fn run_unit_pipelined(conn: &Session, root: &Ref) -> Result<(), String> {
	let create = conn.send(root, "create", &[Argument::Bytes(b"benchmark".to_vec())]);
	conn.tell(&create, "assign", &[Argument::Bytes(b"alice".to_vec())])
		.map_err(|e| format!("assign: {e:?}"))?;
	conn.tell(&create, "complete", &[])
		.map_err(|e| format!("complete: {e:?}"))?;
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

async fn run_latency(locator: &Locator, n: usize) -> Result<(), String> {
	let runtime = open_runtime().await?;
	let conn = runtime
		.connect(locator, ConnectOptions::default())
		.await
		.map_err(|e| format!("connect: {e:?}"))?;
	let serving = conn.serve();
	let root = conn.fetch("root").await.map_err(|e| format!("fetch: {e:?}"))?;
	let mut lats: Vec<f64> = Vec::with_capacity(n);
	for _ in 0..n {
		let s = Instant::now();
		run_unit(&conn, &root).await?;
		lats.push(s.elapsed().as_secs_f64() * 1000.0);
	}
	conn.close(PendingWork::Cancel)
		.await
		.map_err(|e| format!("close session: {e:?}"))?;
	serving.await.map_err(|e| format!("serve session: {e:?}"))?;
	runtime
		.close(PendingWork::Cancel)
		.await
		.map_err(|e| format!("close runtime: {e:?}"))?;
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

async fn run_throughput(locator: &Locator, n: usize) -> Result<(), String> {
	let runtime = open_runtime().await?;
	let conn = runtime
		.connect(locator, ConnectOptions::default())
		.await
		.map_err(|e| format!("connect: {e:?}"))?;
	let serving = conn.serve();
	let root = conn.fetch("root").await.map_err(|e| format!("fetch: {e:?}"))?;
	let t0 = Instant::now();
	for _ in 0..n {
		run_unit_pipelined(&conn, &root).await?;
	}
	let total = t0.elapsed().as_secs_f64() * 1000.0;
	conn.close(PendingWork::Cancel)
		.await
		.map_err(|e| format!("close session: {e:?}"))?;
	serving.await.map_err(|e| format!("serve session: {e:?}"))?;
	runtime
		.close(PendingWork::Cancel)
		.await
		.map_err(|e| format!("close runtime: {e:?}"))?;
	let rps = if total <= 0.0 { 0.0 } else { n as f64 / (total / 1000.0) };
	println!(
        "{{\"v\":1,\"metric\":\"throughput\",\"client\":\"{CLIENT}\",\"suite\":\"taskboard\",\"n\":{n},\"total_ms\":{:.2},\"rps\":{},\"runtime\":\"{RUNTIME}\",\"warmup_n\":0}}",
        total, rps.round() as i64,
    );
	Ok(())
}

async fn run_connections(locator: &Locator, n: usize) -> Result<(), String> {
	let mut warm: Vec<(Runtime, Session)> = Vec::new();
	for _ in 0..n.min(5) {
		warm.push(open_held_connection(locator).await?);
	}
	println!("{{\"v\":1,\"event\":\"warmed\"}}");
	tokio::time::sleep(Duration::from_millis(600)).await;
	let mut handles: Vec<(Runtime, Session)> = Vec::with_capacity(n);
	let t0 = Instant::now();
	for _ in 0..n {
		handles.push(open_held_connection(locator).await?);
	}
	let total = t0.elapsed().as_secs_f64() * 1000.0;
	println!(
        "{{\"v\":1,\"metric\":\"connections\",\"client\":\"{CLIENT}\",\"suite\":\"taskboard\",\"conns\":{n},\"total_ms\":{:.2},\"per_conn_ms\":{:.4},\"runtime\":\"{RUNTIME}\"}}",
        total, total / n.max(1) as f64,
    );
	tokio::time::sleep(Duration::from_millis(2500)).await;
	for (runtime, conn) in handles {
		close_held_connection(runtime, conn).await?;
	}
	for (runtime, conn) in warm {
		close_held_connection(runtime, conn).await?;
	}
	Ok(())
}

/// The local-turn counter behavior: `hit` increments and returns the count,
/// any other verb refuses. A fresh closure per use, so the two paths of
/// `run_local` never share a count.
fn counter_behavior() -> impl FnMut(&str, &[Argument]) -> std::result::Result<Argument, String> + 'static {
	let mut count: i64 = 0;
	move |verb, _args| {
		if verb != "hit" {
			return Err(format!("counter: no such method {verb}"));
		}
		count += 1;
		Ok(Argument::Integer(count))
	}
}

/// Run `n` sequential send→settle hit units against `target`, asserting the
/// final count equals `n` (ahead-of-time, no warmup, so the counter starts at
/// zero). Returns the sorted per-turn latencies in nanoseconds.
async fn measure_hits(conn: &Session, target: &Ref, n: usize) -> Result<Vec<f64>, String> {
	let mut lats: Vec<f64> = Vec::with_capacity(n);
	let mut last: i64 = 0;
	for _ in 0..n {
		let s = Instant::now();
		let reply = conn.send(target, "hit", &[]).await.map_err(|e| format!("hit: {e:?}"))?;
		lats.push(s.elapsed().as_secs_f64() * 1e9);
		last = reply
			.as_i64()
			.ok_or_else(|| format!("hit returned a non-integer: {reply:?}"))?;
	}
	if last != n as i64 {
		return Err(format!("bad final count {last} (expected {n})"));
	}
	lats.sort_by(|a, b| a.partial_cmp(b).unwrap());
	Ok(lats)
}

// The `local` mode (see contract.md): (a) in_lang — a counter spawned on this
// connection, dispatched in process by the binding's own local path; (b)
// via_host — the same behavior published across a loopback pair inside this
// process (listen on 127.0.0.1:0 + connect to itself), so every turn pays wire
// codec, feed, trampoline, and marshal both ways. The orchestrator's host/port
// arguments are unused; the pair is self-contained.
async fn run_local(n: usize) -> Result<(), String> {
	let server = tcp::listen("127.0.0.1", 0, tcp::ListenOptions::default())
		.await
		.map_err(|e| format!("listen: {e:?}"))?;
	let loop_port = server.port().map_err(|e| format!("port: {e:?}"))?;
	// The accept half on its own local task: accept the one dialer, publish the
	// counter (before serving, so the dialer's fetch cannot race it), and serve
	// until the dialer leaves. A failure here would strand the dialer in a
	// blocked read, so it fails the process loudly.
	tokio::task::spawn_local(async move {
		let conn = match server.accept().await {
			Ok(conn) => conn,
			Err(e) => {
				eprintln!("langs-bench local: accept failed: {e:?}");
				std::process::exit(1);
			}
		};
		if let Err(e) = conn.publish("counter", counter_behavior()) {
			eprintln!("langs-bench local: publish failed: {e:?}");
			std::process::exit(1);
		}
		if let Err(e) = conn.serve().await {
			eprintln!("langs-bench local: serve failed: {e:?}");
			std::process::exit(1);
		}
	});
	let runtime = open_runtime().await?;
	let dial = runtime
		.connect(&tcp::locator("127.0.0.1", loop_port), ConnectOptions::default())
		.await
		.map_err(|e| format!("connect: {e:?}"))?;
	let dial_serving = dial.serve();

	// (a) in_lang: the binding's in-process actor dispatch.
	let local = dial.spawn(counter_behavior()).map_err(|e| format!("spawn: {e:?}"))?;
	let in_lang = measure_hits(&dial, &local, n).await?;

	// (b) via_host: the published counter across the loopback pair.
	let far = dial.fetch("counter").await.map_err(|e| format!("fetch: {e:?}"))?;
	let via_host = measure_hits(&dial, &far, n).await?;

	dial.close(PendingWork::Cancel)
		.await
		.map_err(|e| format!("close session: {e:?}"))?;
	dial_serving.await.map_err(|e| format!("serve session: {e:?}"))?;
	runtime
		.close(PendingWork::Cancel)
		.await
		.map_err(|e| format!("close runtime: {e:?}"))?;

	let in_mean = if n == 0 {
		0.0
	} else {
		in_lang.iter().sum::<f64>() / n as f64
	};
	let via_mean = if n == 0 {
		0.0
	} else {
		via_host.iter().sum::<f64>() / n as f64
	};
	let ratio = if in_mean > 0.0 { via_mean / in_mean } else { 0.0 };
	println!(
        "{{\"v\":1,\"metric\":\"local\",\"client\":\"{CLIENT}\",\"suite\":\"local-turn\",\"n\":{n},\"in_lang_ns\":{:.1},\"in_lang_p99_ns\":{:.1},\"via_host_ns\":{:.1},\"via_host_p99_ns\":{:.1},\"ratio\":{:.2},\"runtime\":\"{RUNTIME}\",\"warmup_n\":0}}",
        in_mean, percentile_ms(&in_lang, 0.99), via_mean, percentile_ms(&via_host, 0.99), ratio,
    );
	Ok(())
}

async fn run_cold(locator: &Locator) -> Result<(), String> {
	let runtime = open_runtime().await?;
	let conn = runtime
		.connect(locator, ConnectOptions::default())
		.await
		.map_err(|e| format!("connect: {e:?}"))?;
	let serving = conn.serve();
	let root = conn.fetch("root").await.map_err(|e| format!("fetch: {e:?}"))?;
	run_unit(&conn, &root).await?;
	conn.close(PendingWork::Cancel)
		.await
		.map_err(|e| format!("close session: {e:?}"))?;
	serving.await.map_err(|e| format!("serve session: {e:?}"))?;
	runtime
		.close(PendingWork::Cancel)
		.await
		.map_err(|e| format!("close runtime: {e:?}"))?;
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
	let locator = tcp::locator(&args[2], port);
	let n: usize = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(0);

	let local = tokio::task::LocalSet::new();
	let result = local
		.run_until(async {
			match mode.as_str() {
				"latency" => run_latency(&locator, n).await,
				"throughput" => run_throughput(&locator, n).await,
				"connections" => run_connections(&locator, n).await,
				"cold" => run_cold(&locator).await,
				"local" => run_local(n).await,
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
