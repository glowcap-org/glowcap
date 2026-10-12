//! A supervised child is retained until it exits. Normal shutdown requests
//! SIGTERM. A deadline escalates to kill and still reaps the child.
use super::notice::{Notice, Report};
use crate::server::readiness::Announcement;
use std::{os::unix::fs::DirBuilderExt, path::PathBuf, process::Stdio, time::Duration};
use tokio::{
	io::{AsyncBufReadExt, AsyncReadExt, BufReader},
	process::{Child, Command},
};

pub(super) struct Process {
	pub child: Child,
	pub label: &'static str,
	/// Copies what the child prints after its announcement onto this
	/// process's stderr, for the child's lifetime.
	forward: Option<tokio::task::JoinHandle<std::io::Result<u64>>>,
	report: Option<Report>,
}
impl Process {
	pub fn spawn(command: &mut Command, label: &'static str, report: Report) -> Result<Self, String> {
		let child = command
			.stdin(Stdio::null())
			.stdout(Stdio::piped())
			.stderr(Stdio::inherit())
			.kill_on_drop(true)
			.spawn()
			.map_err(|e| format!("starting {label} failed: {e}"))?;
		Ok(Self {
			child,
			label,
			forward: None,
			report: Some(report),
		})
	}
	/// Supervise a child another owner started, whose output nobody reads.
	pub fn adopted(child: Child, label: &'static str) -> Self {
		Self {
			child,
			label,
			forward: None,
			report: None,
		}
	}
	/// Read the child's one announcement line, then keep its output open:
	/// the rest of what it prints is copied to this process's stderr, so a
	/// stray line after readiness is seen here rather than failing the child
	/// on a pipe nobody reads.
	pub async fn announcement(&mut self, deadline: Duration) -> Result<Announcement, String> {
		let stdout = self
			.child
			.stdout
			.take()
			.ok_or("Rooms server has no announcement stream")?;
		let mut reader = BufReader::new(stdout);
		let read = async {
			let mut line = Vec::new();
			(&mut reader)
				.take(16 * 1024 + 1)
				.read_until(b'\n', &mut line)
				.await
				.map_err(|e| e.to_string())?;
			if line.is_empty() {
				return Err("Rooms server closed its output before announcing readiness".into());
			}
			if line.len() > 16 * 1024 || !line.ends_with(b"\n") {
				return Err("Rooms server announcement is incomplete or too long".into());
			}
			let line = std::str::from_utf8(&line).map_err(|_| "Rooms server announcement is not Unicode")?;
			Announcement::parse(line)
		};
		let announcement = tokio::time::timeout(deadline, read)
			.await
			.map_err(|_| "Rooms server announcement timed out")??;
		self.forward = Some(tokio::spawn(async move {
			let mut stderr = std::io::stderr();
			let mut chunk = [0u8; 4096];
			let mut copied = 0u64;
			loop {
				let read = reader.read(&mut chunk).await?;
				if read == 0 {
					break Ok(copied);
				}
				std::io::Write::write_all(&mut stderr, &chunk[..read])?;
				copied += read as u64;
			}
		}));
		Ok(announcement)
	}
	pub async fn close(&mut self) -> Result<(), String> {
		let result = self.reap().await;
		// The copy ends with the child's pipe. What it reports is this
		// supervisor's to show, since the child is gone.
		if let Some(forward) = self.forward.take() {
			match forward.await {
				Ok(Ok(_)) => {}
				Ok(Err(error)) => self.report(Notice::ChildOutputEnded {
					label: self.label,
					cause: error.to_string(),
				}),
				Err(join) => self.report(Notice::ChildOutputTaskFailed {
					label: self.label,
					cause: join.to_string(),
				}),
			}
		}
		result
	}
	async fn reap(&mut self) -> Result<(), String> {
		if let Some(status) = self.child.try_wait().map_err(|e| e.to_string())? {
			return if status.success() {
				Ok(())
			} else {
				Err(format!("{} exited before shutdown: {status}", self.label))
			};
		}
		let pid = self.child.id().ok_or("supervised child has no process identity")?;
		let sent = nix::sys::signal::kill(
			nix::unistd::Pid::from_raw(pid as i32),
			nix::sys::signal::Signal::SIGTERM,
		);
		if let Err(error) = sent
			&& error != nix::errno::Errno::ESRCH
		{
			self.report(Notice::ChildShutdownRequestFailed(error.to_string()));
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
	fn report(&self, notice: Notice) {
		if let Some(report) = &self.report {
			report(notice);
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
		rooms_platform::entropy::fill(&mut entropy).map_err(|e| e.to_string())?;
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

#[cfg(test)]
mod process_tests {
	use super::*;

	#[tokio::test]
	async fn close_reports_a_child_that_already_failed() {
		let mut command = Command::new("sh");
		command.args(["-c", "exit 7"]);
		let mut process = Process::spawn(&mut command, "test child", std::rc::Rc::new(|_| {})).unwrap();
		let status = process.child.wait().await.unwrap();
		assert!(!status.success());
		let error = process.close().await.unwrap_err();
		assert!(error.contains("test child exited before shutdown"), "{error}");
	}
}
