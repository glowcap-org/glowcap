//! Terminal subscription to the same capability feed as the visualizer.
//! HTTP discovers routing only. Authority comes from a supplied sturdyref or
//! the operator's private state. No compiler or browser runtime is required.
use glowcap::{Argument, CaptpVersion, Host, PendingWork, Session};
use rooms_platform::websocket::WsBytes;
use std::{future::Future, path::PathBuf, time::Duration};

const OPEN_DEADLINE: Duration = Duration::from_secs(15);

pub enum Output {
	Capability(String),
	Record { value: serde_json::Value, json: bool },
}

pub async fn run(
	args: &[String],
	env: impl Fn(&str) -> Option<String>,
	halt: impl Future<Output = ()>,
	mut emit: impl FnMut(Output) -> Result<(), String> + 'static,
) -> Result<(), String> {
	let mut state = env("GLOWCAP_ROOMS_STATE").map(PathBuf::from);
	let port = env("GLOWCAP_ROOMS_HTTP_PORT").unwrap_or_else(|| "8080".into());
	let mut address = format!("http://127.0.0.1:{port}");
	let (mut link, mut json, mut print_link) = (None, false, false);
	let mut discovered_channel = None;
	for arg in args {
		if let Some(path) = arg.strip_prefix("--state=") {
			if path.is_empty() {
				return Err("trace --state needs a directory".into());
			}
			state = Some(path.into());
		} else if let Some(url) = arg.strip_prefix("--url=") {
			address = url.into();
		} else if matches!(arg.as_str(), "--json" | "--json=true") {
			json = true;
		} else if arg == "--json=false" {
			json = false;
		} else if matches!(arg.as_str(), "--print-link" | "--print-link=true") {
			print_link = true;
		} else if arg == "--print-link=false" {
			print_link = false;
		} else if !arg.starts_with('-') && link.is_none() {
			link = Some(arg.clone());
		} else {
			return Err(format!("unknown trace option: {arg}"));
		}
	}
	let link = match link {
		Some(link) => link,
		None => {
			let state = state.ok_or("trace needs a capability or --state=<private-directory>")?;
			let Some(locator) = crate::web::StatusQuery::trace_locator(&address).await? else {
				return if print_link {
					Ok(())
				} else {
					Err("trace is disabled; start the directory with --trace".into())
				};
			};
			// Discovery uses this HTTP front's carried channel. Its advertised
			// route may be public and unreachable from inside the deployment.
			let mut channel = url::Url::parse(&address).map_err(|e| e.to_string())?;
			channel.set_scheme("ws").map_err(|_| "invalid trace discovery origin")?;
			channel.set_path("/trace/captp");
			discovered_channel = Some(channel.to_string());
			let swiss = tokio::task::spawn_blocking(move || {
				let bytes = rooms_platform::storage::read(&state.join("trace"), 256)
					.map_err(|e| e.to_string())?
					.ok_or("trace capability is not minted in this state directory")?;
				let swiss = std::str::from_utf8(&bytes)
					.map_err(|_| "trace capability is not Unicode")?
					.trim();
				if !rooms_application::server::operations::is_swiss(swiss) {
					return Err("trace state is not a complete Swiss number".to_owned());
				}
				Ok(swiss.to_owned())
			})
			.await
			.map_err(|e| format!("reading trace state failed: {e}"))??;
			glowcap::format_sturdyref(&locator, swiss.as_bytes(), CaptpVersion::V1_0).map_err(|e| e.to_string())?
		}
	};
	let parsed = glowcap::parse_sturdyref(&link, CaptpVersion::V1_0).map_err(|e| e.to_string())?;
	if print_link {
		return emit(Output::Capability(link));
	}
	let endpoint = match discovered_channel.as_deref() {
		Some(endpoint) => endpoint,
		None => parsed
			.locator
			.require_string_hint(rooms_application::web_channel::HINT)
			.map_err(|e| e.to_string())?,
	};
	rooms_application::web_channel::endpoint(endpoint)?;
	let mut seed = [0; 32];
	rooms_platform::entropy::fill(&mut seed).map_err(|e| e.to_string())?;
	let host = Host::from_seed(seed).map_err(|e| e.to_string())?;
	let result = follow(&host, &parsed.locator, endpoint, &link, json, halt, emit).await;
	crate::cleanup::combine(result, host.close(PendingWork::Cancel).await.map_err(|e| e.to_string()))
}

async fn follow(
	host: &Host,
	locator: &glowcap::Locator,
	endpoint: &str,
	link: &str,
	json: bool,
	halt: impl Future<Output = ()>,
	mut emit: impl FnMut(Output) -> Result<(), String> + 'static,
) -> Result<(), String> {
	let opened = async {
		let config = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
			.max_message_size(Some(8 << 20))
			.max_frame_size(Some(8 << 20));
		let (socket, _) = tokio_tungstenite::connect_async_with_config(endpoint, Some(config), false)
			.await
			.map_err(|e| e.to_string())?;
		Session::dial_channel(
			host,
			locator,
			WsBytes::new(socket).into_channel(),
			Some(OPEN_DEADLINE),
			None,
		)
		.await
		.map_err(|e| e.to_string())
	};
	tokio::pin!(halt);
	let session = tokio::select! {
		_ = &mut halt => return Ok(()),
		result = tokio::time::timeout(OPEN_DEADLINE, opened) => result.map_err(|_| "trace connection timed out")??,
	};
	let (failed, mut failures) = tokio::sync::mpsc::channel(1);
	let subscribe = async {
		let trace = session.enliven(link).await.map_err(|e| e.to_string())?;
		let inbox = session
			.spawn_owned(move |verb, args| {
				let result = (|| {
					let ("record", [Argument::String(line)]) = (verb, args) else {
						return Err("trace inbox received an invalid record".to_owned());
					};
					if line.len() > rooms_application::server::trace::MAX_LINE_BYTES {
						return Err("trace record exceeds its byte limit".into());
					}
					let record: serde_json::Value = serde_json::from_str(line).map_err(|e| e.to_string())?;
					if !record.is_object() {
						return Err("trace record must be an object".into());
					}
					emit(Output::Record { value: record, json })?;
					Ok(Argument::Void)
				})();
				if let Err(cause) = &result {
					let _ = failed.try_send(cause.clone());
				}
				result
			})
			.map_err(|e| e.to_string())?;
		match session
			.send(&trace, "subscribe", &[Argument::Reference(inbox)])
			.await
			.map_err(|e| e.to_string())?
		{
			Argument::Void => Ok(()),
			_ => Err("trace subscription answered an invalid result".into()),
		}
	};
	let result = tokio::select! {
		_ = &mut halt => None,
		result = tokio::time::timeout(OPEN_DEADLINE, subscribe) => Some(result.map_err(|_| "trace subscription timed out".to_owned()).and_then(|r| r)),
	};
	let result = match result {
		Some(Ok(())) => tokio::select! {
			_ = &mut halt => Ok(()),
			cause = failures.recv() => Err(cause.unwrap_or_else(|| "trace inbox ended".into())),
			ended = session.ended() => Err(match ended { Ok(()) => "trace feed ended".into(), Err(e) => format!("trace feed ended: {e}") }),
		},
		Some(Err(cause)) => Err(cause),
		None => Ok(()),
	};
	crate::cleanup::combine(
		result,
		session.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
	)
}
