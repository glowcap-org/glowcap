//! One Cap'n Proto RPC call round trip over loopback TCP: a client thread and
//! a server thread, each on its own current-thread tokio runtime, both parked
//! between calls.

use std::time::Instant;

use capnp_rpc::{RpcSystem, rpc_twoparty_capnp, twoparty};
use futures::AsyncReadExt;
use nix::sched::{CpuSet, sched_setaffinity};
use nix::unistd::Pid;
use tokio::net::{TcpListener, TcpStream};
use tokio::task::LocalSet;
use tokio_util::compat::TokioAsyncReadCompatExt;

pub mod echo_capnp {
    include!(concat!(env!("OUT_DIR"), "/echo_capnp.rs"));
}
use echo_capnp::echo;

struct EchoImpl;

impl echo::Server for EchoImpl {
    async fn greet(
        self: capnp::capability::Rc<Self>,
        _params: echo::GreetParams,
        mut results: echo::GreetResults,
    ) -> Result<(), capnp::Error> {
        results.get().set_greeting("hello over the wire");
        Ok(())
    }

    async fn report(
        self: capnp::capability::Rc<Self>,
        params: echo::ReportParams,
        mut results: echo::ReportResults,
    ) -> Result<(), capnp::Error> {
        let samples = params.get()?.get_samples()?;
        let mut sum = 0i64;
        for sample in samples.iter() {
            sum += sample;
        }
        let mut out = results.get();
        out.set_count(samples.len());
        out.set_sum(sum);
        Ok(())
    }
}

const SOURCE: &str = "sensor-17/humidity";
const TAGS: [&str; 8] = [
    "site:lab-3",
    "rack:b2",
    "unit:percent",
    "model:sht45",
    "fw:2.4.1",
    "owner:facilities",
    "tier:gold",
    "region:us-west",
];
const SAMPLE_COUNT: usize = 64;
const AT: i64 = 1_760_400_000;
const EXPECTED_COUNT: u32 = 64;
const EXPECTED_SUM: i64 = 22_364_704;

fn print_line(call: &str, samples: &mut [u128], calls: usize, warmup: usize, pinned: bool) {
    samples.sort_unstable();
    let p50 = samples[samples.len() / 2];
    let p99 = samples[samples.len() * 99 / 100];
    let total: u128 = samples.iter().sum();
    let mean = total / samples.len() as u128;
    let rps = 1_000_000_000u128 * samples.len() as u128 / total;
    println!(
        "roundtrip transport=capnp-rust call={call} calls={calls} warmup={warmup} p50_ns={p50} p99_ns={p99} mean_ns={mean} rps={rps} mode=release busy_poll_us=0 pin={}",
        if pinned { "yes" } else { "no" }
    );
}

fn pin(core: Option<usize>) {
    if let Some(core) = core {
        let mut set = CpuSet::new();
        set.set(core).expect("core index");
        sched_setaffinity(Pid::from_raw(0), &set).expect("sched_setaffinity");
    }
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime")
}

fn main() {
    let mut smoke = false;
    let mut pins: Option<(usize, usize)> = None;
    for arg in std::env::args().skip(1) {
        if arg == "--smoke" {
            smoke = true;
        } else if let Some(v) = arg.strip_prefix("--pin=") {
            let (a, b) = v.split_once(',').expect("--pin=A,B");
            pins = Some((a.parse().expect("core A"), b.parse().expect("core B")));
        } else {
            panic!("unknown argument {arg}");
        }
    }
    let (calls, warmup) = if smoke { (200, 50) } else { (3000, 300) };

    let (addr_tx, addr_rx) = std::sync::mpsc::channel();
    let server_core = pins.map(|p| p.1);
    std::thread::spawn(move || {
        pin(server_core);
        let rt = runtime();
        LocalSet::new().block_on(&rt, async move {
            let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
            addr_tx.send(listener.local_addr().expect("addr")).expect("send addr");
            let (stream, _) = listener.accept().await.expect("accept");
            stream.set_nodelay(true).expect("nodelay");
            let (r, w) = stream.compat().split();
            let net = twoparty::VatNetwork::new(r, w, rpc_twoparty_capnp::Side::Server, Default::default());
            let boot: echo::Client = capnp_rpc::new_client(EchoImpl);
            RpcSystem::new(Box::new(net), Some(boot.client)).await.expect("server rpc");
        });
    });
    let addr = addr_rx.recv().expect("server addr");

    pin(pins.map(|p| p.0));
    let rt = runtime();
    let mut samples = Vec::with_capacity(calls);
    let mut report_samples = Vec::with_capacity(calls);
    let input: [i64; SAMPLE_COUNT] = std::array::from_fn(|i| 100_000 + (i as i64 * 7919) % 900_000);
    LocalSet::new().block_on(&rt, async {
        let stream = TcpStream::connect(addr).await.expect("connect");
        stream.set_nodelay(true).expect("nodelay");
        let (r, w) = stream.compat().split();
        let net = twoparty::VatNetwork::new(r, w, rpc_twoparty_capnp::Side::Client, Default::default());
        let mut rpc = RpcSystem::new(Box::new(net), None);
        let client: echo::Client = rpc.bootstrap(rpc_twoparty_capnp::Side::Server);
        tokio::task::spawn_local(rpc);
        for i in 0..warmup + calls {
            let t = Instant::now();
            let mut request = client.greet_request();
            request.get().set_name("world");
            let reply = request.send().promise.await.expect("greet");
            let text = reply.get().expect("reply").get_greeting().expect("greeting").to_str().expect("utf8");
            let ns = t.elapsed().as_nanos();
            assert_eq!(text, "hello over the wire");
            if i >= warmup {
                samples.push(ns);
            }
        }
        for i in 0..warmup + calls {
            let t = Instant::now();
            let mut request = client.report_request();
            {
                let mut params = request.get();
                params.set_source(SOURCE);
                let mut tags = params.reborrow().init_tags(TAGS.len() as u32);
                for (j, tag) in TAGS.iter().enumerate() {
                    tags.set(j as u32, tag);
                }
                let mut values = params.reborrow().init_samples(SAMPLE_COUNT as u32);
                for (j, v) in input.iter().enumerate() {
                    values.set(j as u32, *v);
                }
                params.set_at(AT);
            }
            let reply = request.send().promise.await.expect("report");
            let reply = reply.get().expect("reply");
            let (count, sum) = (reply.get_count(), reply.get_sum());
            let ns = t.elapsed().as_nanos();
            assert_eq!((count, sum), (EXPECTED_COUNT, EXPECTED_SUM));
            if i >= warmup {
                report_samples.push(ns);
            }
        }
    });

    let pinned = pins.is_some();
    print_line("greet", &mut samples, calls, warmup, pinned);
    print_line("report", &mut report_samples, calls, warmup, pinned);
    std::process::exit(0);
}
