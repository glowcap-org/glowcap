//! Per-binding keyed-relay rendezvous proof: the Rust binding cold-dials a
//! non-listening peer by its key designator through the reference relay's
//! rendezvous bridge (ADR-0088). The core classifies the locator as the
//! rendezvous dial shape; the binding opens the WebSocket leg the locator's
//! `rendezvous-relay` hint names, the one rendezvous routing authority.
//!
//! Run via `zig build rust-keyed-relay-rendezvous` (the harness passes
//! `<locator>` after `--`).

use pancake_rust_dogfood::{
	parse_locator, relay, Argument, CarrierPhase, ConnectOptions, Locator, PendingWork, Runtime, RuntimeConfig,
};
use tokio::task::LocalSet;

async fn expect_native_refusal(
	partner: &Locator,
	route: &str,
	trust: relay::Trust<'_>,
	cause: &str,
) -> Result<(), String> {
	let runtime = Runtime::open(RuntimeConfig::providers([relay::provider(
		relay::Config::dial_only(route).with_trust(trust),
	)]))
	.await
	.map_err(|error| error.to_string())?;
	let refused = match runtime
		.connect(
			&relay::keyed::locator(&partner.designator, route),
			ConnectOptions::default(),
		)
		.await
	{
		Ok(session) => {
			session
				.close(PendingWork::Cancel)
				.await
				.map_err(|error| error.to_string())?;
			return Err(format!("native WSS unexpectedly accepted {cause}"));
		}
		Err(error) => error,
	};
	let carrier = refused
		.carrier_failure()
		.ok_or_else(|| format!("native WSS omitted carrier detail: {refused}"))?;
	if carrier.phase != CarrierPhase::SecureHandshake || carrier.verification_flags == 0 {
		return Err(format!(
			"native WSS omitted secure-handshake verification detail: {refused}"
		));
	}
	if !refused.to_string().contains(cause) {
		return Err(format!("native WSS reported {refused}, expected {cause}"));
	}
	runtime
		.close(PendingWork::Cancel)
		.await
		.map_err(|error| error.to_string())
}

async fn scene(locator: String) -> Result<(), String> {
	let partner = parse_locator(&locator).map_err(|error| error.to_string())?;
	let native_route = std::env::var("PANCAKE_PROOF_NATIVE_RELAY_URL").ok();
	let ca_file = std::env::var("PANCAKE_PROOF_NATIVE_RELAY_CA_FILE").ok();
	let copied_pem = match (&native_route, ca_file) {
		(Some(_), Some(path)) => Some(std::fs::read(path).map_err(|error| error.to_string())?),
		(Some(_), None) => return Err("native WSS proof needs PANCAKE_PROOF_NATIVE_RELAY_CA_FILE".to_string()),
		(None, _) => None,
	};
	if let (Some(route), Some(pem)) = (&native_route, &copied_pem) {
		let wrong_host = route.replacen("//localhost:", "//127.0.0.1:", 1);
		expect_native_refusal(
			&partner,
			&wrong_host,
			relay::Trust::CopiedPem(pem),
			"CertificateNameMismatch",
		)
		.await?;
		expect_native_refusal(&partner, route, relay::Trust::System, "CertificateUntrusted").await?;
	}
	let provider = match (&native_route, &copied_pem) {
		(Some(route), Some(pem)) => {
			relay::provider(relay::Config::dial_only(route).with_trust(relay::Trust::CopiedPem(pem)))
		}
		_ => relay::provider_for(&partner).map_err(|error| error.to_string())?,
	};
	let runtime = Runtime::open(RuntimeConfig::providers([provider]))
		.await
		.map_err(|e| e.to_string())?;
	let session = runtime
		.connect(&partner, ConnectOptions::default())
		.await
		.map_err(|e| e.to_string())?;
	let greeter = session.fetch("greeter").await.map_err(|e| e.to_string())?;
	let reply = session
		.send(&greeter, "greet", &[Argument::from("rust")])
		.await
		.map_err(|e| e.to_string())?;
	let expected = "hello rust, cold-dialed by rendezvous";
	match reply {
		Argument::String(s) if s == expected => {}
		other => return Err(format!("unexpected greeting: {other:?}")),
	}
	session.close(PendingWork::Cancel).await.map_err(|e| e.to_string())?;
	runtime.close(PendingWork::Cancel).await.map_err(|e| e.to_string())
}

fn main() {
	// The harness appends the two; a pinned -Dport flag may sit before them.
	let args: Vec<String> = std::env::args().collect();
	if args.len() < 2 {
		eprintln!("usage: keyed_relay_rendezvous <locator>");
		std::process::exit(2);
	}
	let locator = args[args.len() - 1].clone();

	let rt = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap();
	let local = LocalSet::new();
	local.block_on(&rt, async {
		scene(locator).await.expect("rendezvous dial");
		println!(
			"PASS: the Rust binding used the locator's rendezvous-relay route, \
			 and the keyed session answered"
		);
	});
}
