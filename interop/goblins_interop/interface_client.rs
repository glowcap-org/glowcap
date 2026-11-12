//! `interface-goblins-check`: generated Carol receives Bob through plain
//! Goblins Alice, pipelines a positional call, and checks canonical identity.
use glowcap::{CaptpVersion, Codec, ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use std::time::Duration;
use tokio::process::Command;

#[path = "../../test/interface/generated/callbacks.rs"]
pub mod callbacks;
#[path = "../../test/support/transport/rust/client_gate.rs"]
mod client_gate;
#[path = "../../test/interface/generated/expected.rs"]
pub mod expected;

type Fail = client_gate::Fail;
const PORT: u16 = 22261;

fn require(condition: bool, message: &'static str) -> Result<(), Fail> {
	if condition { Ok(()) } else { Err(message.into()) }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Fail> {
	let port = client_gate::parse_port(PORT, 65534)?;
	let mut child = Command::new("racket")
		.args([
			"conformance/goblins-peer/racket/handoff-introducer-host.rkt",
			&port.to_string(),
			&(port + 1).to_string(),
		])
		.stdout(std::process::Stdio::piped())
		.stderr(std::process::Stdio::inherit())
		.kill_on_drop(true)
		.spawn()?;
	let local = tokio::task::LocalSet::new();
	let result = local
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), async {
				let swiss = client_gate::read_swiss(&mut child).await?;
				converse(swiss, port).await
			})
			.await
		})
		.await;
	child.kill().await?;
	child.wait().await?;
	result.map_err(|_| "generated Goblins recipient timed out")?
}

async fn converse(swiss: String, port: u16) -> Result<(), Fail> {
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(tcp::Config {
		profiles: tcp::Profiles::TCP,
		..Default::default()
	})]))
	.await?;
	let session = runtime
		.connect(&tcp::locator("127.0.0.1", port), ConnectOptions::default())
		.await?;
	let profile = session.profile()?;
	require(profile.codec == Codec::Syrup, "negotiated codec was not Syrup")?;
	require(
		profile.captp_version == CaptpVersion::V1_0,
		"negotiated CapTP version was not V1.0",
	)?;
	let introducer = session.fetch(&swiss).await?;
	let introduction = callbacks::introducer_get_greeter(&session, &introducer);
	let pipeline = callbacks::invoke_direct(&session, introduction.raw(), expected::HANDOFF_NAME);
	let greeter = introduction.await?;
	require(
		pipeline.await? == expected::HANDOFF_RESULT,
		"positional pipeline reply differed from the independent fixture",
	)?;
	let again = callbacks::introducer_get_greeter(&session, &introducer).await?;
	require(greeter == again, "handoff replaced the exporter's canonical identity")?;
	require(
		callbacks::invoke_direct(&session, &again, expected::HANDOFF_NAME).await? == expected::HANDOFF_RESULT,
		"settled positional reply differed from the independent fixture",
	)?;
	drop((greeter, again, introducer));
	session.close(PendingWork::Cancel).await?;
	runtime.close(PendingWork::Cancel).await?;
	println!(
		"interface Goblins recipient: Syrup/V1.0, generated introduction, positional pipeline, exact reply and identity passed"
	);
	Ok(())
}
