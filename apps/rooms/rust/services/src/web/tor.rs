//! A private Tor belongs to the web supervisor, across directory restarts.
//! Planning names real endpoints without creating files. Startup acquires the
//! private directory atomically. Externally supplied Tor remains external.
use super::process::{Process, Temporary};
use std::{
	os::{fd::AsFd, unix::fs::FileTypeExt},
	path::PathBuf,
	process::Stdio,
	time::Duration,
};
use tokio::{process::Command, sync::watch};

/// One peer's option reader: its arguments, else its environment.
pub(super) type PeerOptions<'a> = &'a dyn Fn(&str) -> Option<String>;
pub(super) struct Plan {
	root: PathBuf,
	pub endpoints: Endpoints,
}
/// The Tor endpoints an onion listener publishes through, as the peer that
/// listens is told them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Endpoints {
	pub socks: String,
	pub control: String,
}
pub(super) struct Tor {
	process: Process,
	temporary: Temporary,
}
impl Plan {
	/// A private Tor is planned when a peer this front runs announces an
	/// onion listener and names no running Tor of its own. Each entry of
	/// `peers` answers that peer's option names, from its arguments or its
	/// environment. A peer naming one of the two endpoints without the other
	/// is refused.
	pub fn read(peers: &[PeerOptions<'_>], env: impl Fn(&str) -> Option<String>) -> Result<Option<Self>, String> {
		let mut wanted = false;
		for value in peers {
			if value("transport").as_deref() != Some("onion") {
				continue;
			}
			let socks = value("onion-socks")
				.or_else(|| env("GLOWCAP_ONION_SOCKS"))
				.filter(|s| !s.trim().is_empty());
			let control = value("onion-control")
				.or_else(|| env("GLOWCAP_ONION_CONTROL"))
				.filter(|s| !s.trim().is_empty());
			match (socks, control) {
				(Some(_), Some(_)) => {}
				(None, None) => wanted = true,
				_ => return Err("onion SOCKS and control endpoints must be set together".into()),
			}
		}
		if !wanted {
			return Ok(None);
		}
		let root = Temporary::plan()?;
		let path = root.to_str().ok_or("private Tor directory must be Unicode")?;
		if path.contains(['\n', '\r', '\0']) {
			return Err("private Tor directory contains a control character".into());
		}
		Ok(Some(Self {
			endpoints: Endpoints {
				socks: format!("{path}/socks.sock"),
				control: format!("{path}/control.sock"),
			},
			root,
		}))
	}
}
impl Tor {
	pub async fn open(plan: Plan, mut stop: watch::Receiver<bool>) -> Result<Option<Self>, String> {
		if *stop.borrow() {
			return Ok(None);
		}
		let (root, temporary) = Temporary::create(plan.root).await?;
		let starting = async {
			let quote = |value: &str| format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""));
			let data = quote(root.join("data").to_str().ok_or("Tor path is not Unicode")?);
			let torrc = format!(
				"DataDirectory {data}\nSocksPort {}\nControlPort {}\nCookieAuthentication 0\nLog warn stderr\n",
				quote(&format!("unix:{}", plan.endpoints.socks)),
				quote(&format!("unix:{}", plan.endpoints.control))
			);
			tokio::fs::write(root.join("torrc"), torrc)
				.await
				.map_err(|e| e.to_string())?;
			if *stop.borrow() {
				return Ok(None);
			}
			// Tor can fail before its configured logger starts. Route both
			// streams to the operator, never into the web readiness stream or
			// an unbounded private log file that disappears on failed startup.
			let output = std::io::stderr()
				.as_fd()
				.try_clone_to_owned()
				.map_err(|e| e.to_string())?;
			let child = Command::new("tor")
				.arg("-f")
				.arg(root.join("torrc"))
				.stdin(Stdio::null())
				.stdout(Stdio::from(output))
				.stderr(Stdio::inherit())
				.kill_on_drop(true)
				.spawn()
				.map_err(|e| format!("starting private Tor failed: {e}"))?;
			Ok::<_, String>(Some(Process::adopted(child, "Tor")))
		}
		.await;
		let process = match starting {
			Ok(Some(process)) => process,
			Ok(None) => {
				temporary.close().await?;
				return Ok(None);
			}
			Err(error) => {
				return Err(crate::cleanup::failed(error, temporary.close().await));
			}
		};
		let mut tor = Self { process, temporary };
		let ready = async {
			loop {
				if let Some(status) = tor.process.child.try_wait().map_err(|e| e.to_string())? {
					return Err(format!("private Tor exited during startup: {status}"));
				}
				let socket = async |name: &str| {
					tokio::fs::metadata(root.join(name))
						.await
						.is_ok_and(|m| m.file_type().is_socket())
				};
				// Publication uses Tor's control endpoint. SOCKS belongs to
				// outgoing circuit dialing and may be disabled independently.
				if socket("control.sock").await {
					return Ok(());
				}
				tokio::time::sleep(Duration::from_millis(100)).await;
			}
		};
		let ready = tokio::select! {
			biased;
			_ = super::stopped(&mut stop) => Ok(false),
			ready = tokio::time::timeout(Duration::from_secs(60), ready) => ready
				.map_err(|_| "private Tor control endpoint did not appear".to_owned()).and_then(|r| r).map(|()| true),
		};
		match ready {
			Ok(true) => Ok(Some(tor)),
			Ok(false) => {
				tor.close().await?;
				Ok(None)
			}
			Err(error) => Err(crate::cleanup::failed(error, tor.close().await)),
		}
	}

	/// Why the private Tor process is gone. It is never expected to end.
	pub async fn ended(&mut self) -> String {
		match self.process.child.wait().await {
			Ok(status) => format!("private Tor exited: {status}"),
			Err(error) => error.to_string(),
		}
	}
	pub async fn close(mut self) -> Result<(), String> {
		self.process.close().await?;
		self.temporary.close().await
	}
}
