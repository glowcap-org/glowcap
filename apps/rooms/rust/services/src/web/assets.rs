//! Immutable asset generations: concurrent responses clone byte handles, not
//! file bodies. A changed source graph becomes visible only as a complete
//! generation. Compilation failures refuse new pages and preserve old chunks.
use super::{
	bundle,
	notice::{Notice, Report},
	source::Graph,
};
use base64::Engine;
use bytes::Bytes;
use hyper::{
	StatusCode,
	header::{HeaderMap, HeaderValue},
};
use sha2::{Digest, Sha256};
use std::rc::Rc;
use std::{
	cell::RefCell,
	collections::BTreeMap,
	io::Read,
	path::{Path, PathBuf},
	time::Duration,
};
use tokio::{
	sync::{Notify, watch},
	time::Instant,
};

const MAX_ASSET: usize = 64 * 1024 * 1024;
const MAX_GENERATION: usize = 128 * 1024 * 1024;
#[derive(Clone)]
pub(super) struct Asset {
	pub body: Bytes,
	pub content_type: &'static str,
	pub etag: HeaderValue,
	pub headers: HeaderMap,
}
pub(super) struct Generation {
	files: BTreeMap<String, Asset>,
	revision: Asset,
	bytes: usize,
}
struct State {
	current: Generation,
	previous: Option<Generation>,
	stamp: Option<[u8; 32]>,
	checked: Instant,
	failed: Option<String>,
}
impl State {
	/// Reconcile one attempted source stamp with the generation it produced.
	/// A failed attempt is not accepted as current: the same source graph must
	/// remain eligible for retry after the refresh interval.
	fn finish_refresh(&mut self, stamp: [u8; 32], generation: Result<Option<Generation>, String>) {
		match generation {
			Ok(Some(generation)) => {
				self.previous = Some(std::mem::replace(&mut self.current, generation));
				self.stamp = Some(stamp);
				self.failed = None;
			}
			Ok(None) => self.failed = Some("web service is stopping".into()),
			Err(error) => self.failed = Some(error),
		}
	}
}
pub(super) struct Assets {
	root: PathBuf,
	browser_admission: String,
	prepared: bool,
	state: RefCell<State>,
	refresh: Notify,
	updated: watch::Sender<()>,
	stop: watch::Receiver<bool>,
	report: Report,
}
impl Assets {
	pub async fn open(
		root: PathBuf,
		prepared: bool,
		stop: watch::Receiver<bool>,
		report: Report,
		browser_admission: String,
	) -> Result<Option<Rc<Self>>, String> {
		if *stop.borrow() {
			return Ok(None);
		}
		let graph = if prepared {
			None
		} else {
			Some(bundle::graph(&root).await?)
		};
		let stamp = graph.as_ref().map(|graph| graph.stamp);
		let Some(current) = Self::generation(&root, graph, stop.clone(), &report, browser_admission.clone()).await?
		else {
			return Ok(None);
		};
		Ok(Some(Rc::new(Self {
			root,
			browser_admission,
			prepared,
			refresh: Notify::new(),
			updated: watch::channel(()).0,
			stop,
			report,
			state: RefCell::new(State {
				current,
				previous: None,
				stamp,
				checked: Instant::now(),
				failed: None,
			}),
		})))
	}
	async fn generation(
		root: &Path,
		graph: Option<Graph>,
		stop: watch::Receiver<bool>,
		report: &Report,
		browser_admission: String,
	) -> Result<Option<Generation>, String> {
		if *stop.borrow() {
			return Ok(None);
		}
		let directory = if graph.is_some() {
			root.join("../../../zig-out/rooms-web/current")
		} else {
			root.to_owned()
		};
		let mut temporary = None;
		let directory = if let Some(graph) = graph {
			let version = bundle::version(graph).await?;
			let prepared = tokio::fs::read_to_string(directory.join("source.version")).await.ok();
			if prepared.as_deref().map(str::trim) == Some(version.as_str()) {
				directory
			} else {
				report(Notice::CompilingAssets);
				let Some((directory, owner)) = bundle::build(root, &version, stop, None).await? else {
					return Ok(None);
				};
				temporary = Some(owner);
				directory
			}
		} else {
			directory
		};
		let result = tokio::task::spawn_blocking(move || Generation::load_configured(&directory, &browser_admission))
			.await
			.map_err(|e| e.to_string())
			.and_then(|r| r);
		if let Some(owner) = temporary {
			let cleanup = owner.close().await;
			match result {
				Ok(generation) => {
					cleanup?;
					Ok(Some(generation))
				}
				Err(error) => Err(crate::cleanup::failed(error, cleanup)),
			}
		} else {
			result.map(Some)
		}
	}

	async fn refresh(&self) -> Result<(), String> {
		if self.prepared {
			return Ok(());
		}
		if self.state.borrow().checked.elapsed() < Duration::from_secs(1) {
			return Ok(());
		}
		let graph = match bundle::graph(&self.root).await {
			Ok(graph) => graph,
			Err(error) => {
				let mut state = self.state.borrow_mut();
				state.failed = Some(error.clone());
				state.stamp = None;
				state.checked = Instant::now();
				return Err(error);
			}
		};
		let stamp = graph.stamp;
		let changed = self.state.borrow().stamp != Some(stamp);
		if changed {
			let generation = Self::generation(
				&self.root,
				Some(graph),
				self.stop.clone(),
				&self.report,
				self.browser_admission.clone(),
			)
			.await;
			self.state.borrow_mut().finish_refresh(stamp, generation);
		}
		self.state.borrow_mut().checked = Instant::now();
		Ok(())
	}
	/// Refresh is owned by the service, not the HTTP request that noticed an
	/// edit. Dropping a browser connection cannot abandon a compiler or its
	/// temporary files. Shutdown wakes and joins this owner.
	pub async fn run(self: Rc<Self>) -> Result<(), String> {
		let mut stop = self.stop.clone();
		loop {
			tokio::select! {
				biased;
				_ = super::stopped(&mut stop) => break,
				_ = self.refresh.notified() => {},
			}
			if let Err(error) = self.refresh().await {
				(self.report)(Notice::AssetRefreshFailed(error));
			}
			self.updated.send_replace(());
		}
		self.state.borrow_mut().failed = Some("web service is stopping".into());
		self.updated.send_replace(());
		Ok(())
	}

	pub async fn get(&self, path: &str) -> Result<Option<Asset>, String> {
		// Already-issued pages can load their immutable chunks while a new
		// generation compiles. Only new entrypoints wait for freshness.
		if (path.ends_with(".js") && path != "/page.js") || path.starts_with("/rooms-") && path.ends_with(".wasm") {
			let state = self.state.borrow();
			if let Some(asset) = state
				.current
				.files
				.get(path)
				.or_else(|| state.previous.as_ref().and_then(|old| old.files.get(path)))
			{
				return Ok(Some(asset.clone()));
			}
		}
		let mut updated = self.updated.subscribe();
		let mut stop = self.stop.clone();
		while !self.prepared && self.state.borrow().checked.elapsed() >= Duration::from_secs(1) {
			self.refresh.notify_one();
			tokio::select! {
				_ = super::stopped(&mut stop) => return Err("web service is stopping".into()),
				_ = updated.changed() => {},
			}
		}
		let state = self.state.borrow();
		if let Some(error) = &state.failed {
			return Err(error.clone());
		}
		if path == "/ui-version" {
			return Ok(Some(state.current.revision.clone()));
		}
		let key = if state.current.files.contains_key(path) {
			path
		} else if path.ends_with(".js")
			|| path.ends_with(".css")
			|| path.ends_with(".wasm")
			|| path.starts_with("/fonts/")
		{
			return Ok(None);
		} else {
			"/"
		};
		state
			.current
			.files
			.get(key)
			.cloned()
			.map(Some)
			.ok_or("browser asset is unavailable".into())
	}
}
impl Generation {
	pub(super) fn load(bundle: &Path) -> Result<Self, String> {
		Self::load_configured(bundle, "{}")
	}
	fn load_configured(bundle: &Path, browser_admission: &str) -> Result<Self, String> {
		// Resolve a publication pointer once so a concurrent preparation cannot
		// mix files from different immutable generations during startup.
		let bundle = std::fs::canonicalize(bundle).map_err(|e| e.to_string())?;
		let revision = text(&bundle.join("revision"), 128)?.trim().to_owned();
		if !super::source::revision(&revision) {
			return Err("browser bundle revision is malformed".into());
		}
		let identity = text(&bundle.join("source.version"), 128)?;
		if !super::rendezvous::designator(identity.trim()) {
			return Err("browser bundle source identity is malformed".into());
		}
		let mut generation = Self {
			files: BTreeMap::new(),
			revision: Asset::new(format!("{revision}\n").into(), "text/plain; charset=utf-8")?,
			bytes: 0,
		};
		let application = read(&bundle.join("rooms_browser_bg.wasm"), MAX_ASSET)?;
		let application_path = format!(
			"/rooms-{}.wasm",
			rooms_application::fields::lower_hex(&Sha256::digest(&application))
		);
		generation.insert(
			application_path.clone(),
			Asset::new(application.into(), "application/wasm")?,
		)?;
		for entry in std::fs::read_dir(&bundle).map_err(|e| e.to_string())? {
			let entry = entry.map_err(|e| e.to_string())?;
			let name = entry
				.file_name()
				.into_string()
				.map_err(|_| "browser bundle filename is not Unicode")?;
			if entry.file_type().map_err(|e| e.to_string())?.is_file() && name.ends_with(".js") && leaf(&name) {
				let mut body = read(&entry.path(), MAX_ASSET)?;
				if name == "page.js" {
					let prefix = format!(
						"document.documentElement.dataset.uiBuild={};\ndocument.documentElement.dataset.roomsWasm={};\ndocument.documentElement.dataset.roomsSessionAdmission={};\n",
						serde_json::to_string(&revision).map_err(|e| e.to_string())?,
						serde_json::to_string(&application_path).map_err(|e| e.to_string())?,
						serde_json::to_string(browser_admission).map_err(|e| e.to_string())?
					);
					let mut main = prefix.into_bytes();
					main.append(&mut body);
					body = main;
				}
				let route = format!("/{name}");
				generation.insert(route, Asset::new(body.into(), "text/javascript; charset=utf-8")?)?;
			}
		}
		if !generation.files.contains_key("/page.js") {
			return Err("browser bundle has no page.js".into());
		}
		let page = text(&bundle.join("page.html"), MAX_ASSET)?;
		let mut html = Asset::new(page.as_bytes().to_vec().into(), "text/html; charset=utf-8")?;
		html.headers = security(&page)?;
		generation.insert("/".into(), html)?;
		for (folder, suffix, content_type, route) in [
			("", ".css", "text/css; charset=utf-8", ""),
			("fonts", ".woff2", "font/woff2", "fonts/"),
			("fonts", ".txt", "text/plain; charset=utf-8", "fonts/"),
		] {
			for entry in std::fs::read_dir(bundle.join(folder)).map_err(|e| e.to_string())? {
				let entry = entry.map_err(|e| e.to_string())?;
				let name = entry
					.file_name()
					.into_string()
					.map_err(|_| "asset filename is not Unicode")?;
				if name.ends_with(suffix)
					&& leaf(&name) && std::fs::metadata(entry.path()).map_err(|e| e.to_string())?.is_file()
				{
					generation.insert(
						format!("/{route}{name}"),
						Asset::new(read(&entry.path(), MAX_ASSET)?.into(), content_type)?,
					)?;
				}
			}
		}
		Ok(generation)
	}
	fn insert(&mut self, path: String, asset: Asset) -> Result<(), String> {
		if asset.body.len() > MAX_GENERATION - self.bytes {
			return Err("browser generation exceeds its byte budget".into());
		}
		self.bytes += asset.body.len();
		self.files.insert(path, asset);
		Ok(())
	}
}
impl Asset {
	fn new(body: Bytes, content_type: &'static str) -> Result<Self, String> {
		let etag = HeaderValue::from_str(&format!(
			"\"{}\"",
			rooms_application::fields::lower_hex(&Sha256::digest(&body))
		))
		.map_err(|e| e.to_string())?;
		Ok(Self {
			body,
			content_type,
			etag,
			headers: HeaderMap::new(),
		})
	}
	pub fn response(self, request: &hyper::Request<hyper::body::Incoming>) -> super::http::Reply {
		let matches = request
			.headers()
			.get("if-none-match")
			.and_then(|h| h.to_str().ok())
			.is_some_and(|header| {
				header.split(',').map(str::trim).any(|tag| {
					tag == "*"
						|| self
							.etag
							.to_str()
							.is_ok_and(|etag| tag.strip_prefix("W/").unwrap_or(tag) == etag)
				})
			});
		let mut response = super::http::response(
			if matches {
				StatusCode::NOT_MODIFIED
			} else {
				StatusCode::OK
			},
			self.content_type,
			if matches { Bytes::new() } else { self.body },
		);
		response.headers_mut().extend(self.headers);
		response.headers_mut().insert("etag", self.etag);
		if request.uri().path() != "/ui-version" {
			response
				.headers_mut()
				.insert("cache-control", HeaderValue::from_static("no-cache"));
		}
		response
	}
}
pub(super) fn read(path: &Path, limit: usize) -> Result<Vec<u8>, String> {
	let mut bytes = Vec::new();
	std::fs::File::open(path)
		.map_err(|e| format!("{}: {e}", path.display()))?
		.take(limit as u64 + 1)
		.read_to_end(&mut bytes)
		.map_err(|e| e.to_string())?;
	if bytes.len() > limit {
		return Err("asset exceeds its byte budget".into());
	}
	Ok(bytes)
}
fn text(path: &Path, limit: usize) -> Result<String, String> {
	String::from_utf8(read(path, limit)?).map_err(|_| "text asset is not Unicode".into())
}
fn leaf(name: &str) -> bool {
	!name.is_empty()
		&& name
			.bytes()
			.all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
		&& !name.contains("..")
}
fn security(page: &str) -> Result<HeaderMap, String> {
	let mut hashes = String::new();
	let mut rest = page;
	while let Some((_, tail)) = rest.split_once("<script>") {
		let (body, tail) = tail.split_once("</script>").ok_or("page inline script is unclosed")?;
		let hash = base64::engine::general_purpose::STANDARD.encode(Sha256::digest(body.as_bytes()));
		hashes.push_str(&format!(" 'sha256-{hash}'"));
		rest = tail;
	}
	let csp = format!(
		"default-src 'self'; base-uri 'none'; connect-src 'self' ws: wss:; font-src 'self'; form-action 'self'; frame-ancestors 'none'; img-src 'self' blob: data:; media-src 'self' blob:; object-src 'none'; script-src 'self' 'wasm-unsafe-eval'{hashes}; style-src 'self' 'unsafe-inline'; worker-src 'self' blob:"
	);
	let mut headers = HeaderMap::new();
	headers.insert(
		"content-security-policy",
		HeaderValue::from_str(&csp).map_err(|e| e.to_string())?,
	);
	for (name, value) in [
		("cross-origin-opener-policy", "same-origin"),
		(
			"permissions-policy",
			"camera=(), display-capture=(), geolocation=(), microphone=()",
		),
		("referrer-policy", "no-referrer"),
		("x-content-type-options", "nosniff"),
		("x-frame-options", "DENY"),
	] {
		headers.insert(name, HeaderValue::from_static(value));
	}
	Ok(headers)
}

#[cfg(test)]
mod tests {
	use super::*;

	fn generation(label: &str) -> Generation {
		Generation {
			files: BTreeMap::new(),
			revision: Asset::new(Bytes::copy_from_slice(label.as_bytes()), "text/plain").unwrap(),
			bytes: 0,
		}
	}

	#[test]
	fn failed_refresh_does_not_accept_the_attempted_source_stamp() {
		let old = [1; 32];
		let new = [2; 32];
		let mut state = State {
			current: generation("old"),
			previous: None,
			stamp: Some(old),
			checked: Instant::now(),
			failed: None,
		};
		state.finish_refresh(new, Err("compiler unavailable".into()));
		assert_eq!(state.stamp, Some(old), "the same graph remains retryable");
		assert_eq!(state.failed.as_deref(), Some("compiler unavailable"));

		state.finish_refresh(new, Ok(Some(generation("new"))));
		assert_eq!(state.stamp, Some(new));
		assert!(state.failed.is_none());
		assert!(state.previous.is_some());
	}
}
