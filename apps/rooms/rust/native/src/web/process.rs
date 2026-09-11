//! A supervised child is retained until it exits. Normal shutdown requests
//! SIGTERM; a deadline escalates to kill and still reaps the child.
use crate::room_server::readiness::Announcement;
use std::{os::unix::fs::DirBuilderExt, path::PathBuf, process::Stdio, time::Duration};
use tokio::{
	io::{AsyncBufReadExt, AsyncReadExt, BufReader},
	process::{Child, Command},
};

pub(super) struct Process {
	pub child: Child,
	pub label: &'static str,
}
impl Process {
	pub fn spawn(command: &mut Command, label: &'static str) -> Result<Self, String> {
		let child = command
			.stdin(Stdio::null())
			.stdout(Stdio::piped())
			.stderr(Stdio::inherit())
			.kill_on_drop(true)
			.spawn()
			.map_err(|e| format!("starting {label} failed: {e}"))?;
		Ok(Self { child, label })
	}
	pub async fn announcement(&mut self, deadline: Duration) -> Result<Announcement, String> {
		let stdout = self
			.child
			.stdout
			.take()
			.ok_or("room server has no announcement stream")?;
		let read = async {
			let mut reader = BufReader::new(stdout.take(16 * 1024 + 1));
			let mut line = Vec::new();
			reader.read_until(b'\n', &mut line).await.map_err(|e| e.to_string())?;
			if line.is_empty() {
				return Err("room server closed its output before announcing readiness".into());
			}
			if line.len() > 16 * 1024 || !line.ends_with(b"\n") {
				return Err("room server announcement is incomplete or too long".into());
			}
			let line = std::str::from_utf8(&line).map_err(|_| "room server announcement is not Unicode")?;
			Announcement::parse(line)
		};
		tokio::time::timeout(deadline, read)
			.await
			.map_err(|_| "room server announcement timed out")?
	}
	pub async fn close(&mut self) -> Result<(), String> {
		if self.child.try_wait().map_err(|e| e.to_string())?.is_some() {
			return Ok(());
		}
		let pid = self.child.id().ok_or("supervised child has no process identity")?;
		let sent = nix::sys::signal::kill(
			nix::unistd::Pid::from_raw(pid as i32),
			nix::sys::signal::Signal::SIGTERM,
		);
		if let Err(error) = sent {
			if error != nix::errno::Errno::ESRCH {
				eprintln!("rooms web: requesting child shutdown failed: {error}");
			}
		}
		match tokio::time::timeout(Duration::from_secs(30), self.child.wait()).await {
			Ok(result) => {
				let status = result.map_err(|e| e.to_string())?;
				if status.success() {
					Ok(())
				} else {
					Err(format!("{} exited during shutdown: {status}", self.label))
				}
			}
			Err(_) => {
				self.child.kill().await.map_err(|e| e.to_string())?;
				Err(format!("{} exceeded its shutdown deadline and was killed", self.label))
			}
		}
	}
}

pub(super) struct Temporary(Option<PathBuf>);
impl Temporary {
	pub async fn state(configured: Option<PathBuf>) -> Result<(PathBuf, Self), String> {
		if let Some(path) = configured {
			return Ok((path, Self(None)));
		}
		Self::create(Self::plan()?).await
	}
	pub fn plan() -> Result<PathBuf, String> {
		let mut entropy = [0u8; 16];
		getrandom::fill(&mut entropy).map_err(|e| e.to_string())?;
		let name: String = entropy.iter().map(|b| format!("{b:02x}")).collect();
		Ok(std::env::temp_dir().join(format!("glowcap-rooms-{name}")))
	}
	pub async fn create(path: PathBuf) -> Result<(PathBuf, Self), String> {
		tokio::task::spawn_blocking(move || {
			std::fs::DirBuilder::new()
				.mode(0o700)
				.create(&path)
				.map_err(|e| e.to_string())?;
			Ok((path.clone(), Self(Some(path))))
		})
		.await
		.map_err(|e| e.to_string())?
	}

	pub async fn close(mut self) -> Result<(), String> {
		let Some(path) = self.0.take() else {
			return Ok(());
		};
		tokio::task::spawn_blocking(move || std::fs::remove_dir_all(path))
			.await
			.map_err(|e| e.to_string())?
			.map_err(|e| e.to_string())
	}
	pub async fn relocate(&mut self, destination: PathBuf) -> Result<(), String> {
		let source = self.0.as_ref().ok_or("cannot move externally owned state")?;
		tokio::fs::rename(source, &destination)
			.await
			.map_err(|e| e.to_string())?;
		self.0 = Some(destination);
		Ok(())
	}
	/// Publication transferred this generated directory to the artifact store.
	pub fn persist(mut self) {
		self.0.take();
	}
}
