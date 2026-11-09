//! What a relay admits: the pages that may use this server, the connection
//! budget they share, and the directories it forwards TCP to.
use hyper::Request;
use tokio::sync::Semaphore;

/// iroh sessions a relay runs at once unless the operator sets a limit.
const DEFAULT_IROH_SESSIONS: usize = 16;
#[derive(Clone)]
pub(in crate::web) struct Limits {
	pub sessions: usize,
	pub iroh: usize,
	pub starts: usize,
	pub tcp: Vec<(String, u16)>,
	/// Page origins besides this server's own that may relay and register
	/// through it, such as a static host serving the Rooms page.
	pub origins: Vec<url::Origin>,
	/// The listed entries that named a Rooms page's own address, not only its
	/// origin, so the server can print a link that opens each with it.
	pub pages: Vec<url::Url>,
	/// The entries as the operator wrote them, so a refusal can print the
	/// list that admits one page more.
	pub listed: Vec<String>,
	pub registrations: usize,
	pub per_identity: usize,
}
/// The Rooms page the website publishes, which a server lets use it unless
/// `--allow-origin` or `GLOWCAP_RELAY_ALLOW_ORIGINS` names other pages, or
/// none. A macro, so the option's help carries the same literal.
macro_rules! site_page {
	() => {
		"https://glowcap.org/rooms/app/"
	};
}
pub(in crate::web) use site_page;
pub(super) const SITE_PAGE: &str = site_page!();

impl Limits {
	pub fn read(env: impl Fn(&str) -> Option<String>) -> Result<Self, String> {
		// Relays share the HTTP front's connection table. Reserve one eighth for
		// page assets, locators, ICE, status, and proxy requests; rendezvous rows
		// each retain one of the same HTTP connections, so their independent cap
		// cannot usefully exceed the table itself.
		const DEFAULT_SESSIONS: usize = super::super::http::MAX_CONNECTIONS * 7 / 8;
		const DEFAULT_REGISTRATIONS: usize = super::super::http::MAX_CONNECTIONS;
		let cap = |name, fallback| match env(name).filter(|s| !s.is_empty()) {
			None => Ok(fallback),
			Some(value) => value
				.parse::<usize>()
				.ok()
				.filter(|n| *n > 0 && *n <= Semaphore::MAX_PERMITS)
				.ok_or_else(|| format!("{name} must be a positive capacity")),
		};
		let iroh = cap("GLOWCAP_RELAY_MAX_IROH_SESSIONS", DEFAULT_IROH_SESSIONS)?;
		let tcp = env("GLOWCAP_RELAY_TCP_PEERS")
			.unwrap_or_default()
			.split(',')
			.map(str::trim)
			.filter(|s| !s.is_empty())
			.map(|s| glowcap::designator_host_port(s).map_err(|e| e.to_string()))
			.collect::<Result<_, _>>()?;
		let listed: Vec<String> = env("GLOWCAP_RELAY_ALLOW_ORIGINS")
			.unwrap_or_else(|| SITE_PAGE.to_owned())
			.split(',')
			.map(str::trim)
			.filter(|s| !s.is_empty())
			.map(str::to_owned)
			.collect();
		let addresses = listed
			.iter()
			.map(|entry| page_entry(entry))
			.collect::<Result<Vec<_>, _>>()?;
		let origins = addresses.iter().map(url::Url::origin).collect();
		// An entry written with its path, `/` included, names a page, even one
		// at the root of its origin. An entry written as a bare origin names the
		// origin alone, and its address reads as the path `/`.
		let pages = listed
			.iter()
			.zip(addresses)
			.filter(|(entry, _)| entry.ends_with('/'))
			.map(|(_, page)| page)
			.collect();
		Ok(Self {
			origins,
			pages,
			listed,
			sessions: cap("GLOWCAP_RELAY_MAX_SESSIONS", DEFAULT_SESSIONS)?,
			registrations: cap("GLOWCAP_RELAY_MAX_REGISTRATIONS", DEFAULT_REGISTRATIONS)?,
			per_identity: cap("GLOWCAP_RELAY_MAX_REGISTRATIONS_PER_IDENTITY", 4)?,
			iroh,
			starts: cap("GLOWCAP_RELAY_MAX_IROH_DIALS_PER_MINUTE", iroh.saturating_mul(2))?,
			tcp,
		})
	}
}
/// Whether a request may use this server: no `Origin` (not a browser), this
/// server's own page, or a page origin in `listed`.
pub(in crate::web) fn origin_allowed<B>(request: &Request<B>, listed: &[url::Origin]) -> bool {
	let Some(origin) = request.headers().get("origin") else {
		return true;
	};
	let Ok(origin) = origin.to_str().ok().and_then(|s| url::Url::parse(s).ok()).ok_or(()) else {
		return false;
	};
	if !matches!(origin.scheme(), "http" | "https") {
		return false;
	}
	let own = request.headers().get("host").and_then(|v| v.to_str().ok());
	own == Some(&origin[url::Position::BeforeHost..url::Position::AfterPort]) || listed.contains(&origin.origin())
}
/// One `GLOWCAP_RELAY_ALLOW_ORIGINS` entry: an http or https origin, or the
/// address of a Rooms page on one, which is a path ending in `/`. A path with
/// no final `/` could be a file or a directory, so it is refused, not guessed.
fn page_entry(entry: &str) -> Result<url::Url, String> {
	let refused = || {
		format!(
			"--allow-origin (or GLOWCAP_RELAY_ALLOW_ORIGINS) entry {entry:?} must be an origin such as https://rooms.example, or a page address such as https://rooms.example/rooms/app/"
		)
	};
	exact_address(entry).ok_or_else(refused)
}
/// An http(s) address written as a page or server base: no credentials, a
/// path ending in `/`, and no query or fragment, so the path the operator
/// typed is the path every link carries. A bare origin reads as the path `/`,
/// the one form the URL standard gives it.
pub(in crate::web) fn exact_address(entry: &str) -> Option<url::Url> {
	let url = url::Url::parse(entry).ok()?;
	let exact = matches!(url.scheme(), "http" | "https")
		&& url.username().is_empty()
		&& url.password().is_none()
		&& url.path().ends_with('/')
		&& url.query().is_none()
		&& url.fragment().is_none();
	exact.then_some(url)
}
