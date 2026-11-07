//! Write a prepared browser generation as plain files for a static host, built
//! for one base path. The files are the ones `rooms-web` serves from memory,
//! with the same injected page values, so a static host and `rooms-web` load
//! one build. The base path is written into the page's `<base>` element, which
//! the page and its router resolve against. The server's own routes are not
//! part of the export.
//!
//! A static host sends none of `rooms-web`'s headers, so the page carries the
//! two policies a `<meta>` element can: content security and referrer.
use super::assets::{Generation, content_policy};
use std::path::{Path, PathBuf};

/// The page's base element as the source page carries it, at `/`.
const SOURCE_BASE: &str = r#"<base href="/" />"#;

pub struct StaticExport {
	assets: PathBuf,
	output: PathBuf,
	base: String,
}
impl StaticExport {
	/// `--export-static=<directory> --assets=<prepared generation> [--base=<path>]`,
	/// or `None` when the first argument is not this mode.
	pub fn parse(args: &[String]) -> Result<Option<Self>, String> {
		let Some(output) = args.first().and_then(|arg| arg.strip_prefix("--export-static=")) else {
			return Ok(None);
		};
		if output.is_empty() {
			return Err("--export-static requires an output directory".into());
		}
		let (mut assets, mut base) = (None, None);
		for arg in &args[1..] {
			if let Some(value) = arg.strip_prefix("--assets=").filter(|s| !s.is_empty()) {
				if assets.replace(value).is_some() {
					return Err("--assets is given twice".into());
				}
			} else if let Some(value) = arg.strip_prefix("--base=") {
				if base.replace(value).is_some() {
					return Err("--base is given twice".into());
				}
			} else {
				return Err(format!("a static export accepts only --assets and --base, not {arg}"));
			}
		}
		let assets = assets.ok_or("a static export requires --assets=<prepared generation>")?;
		let base = base.unwrap_or("/");
		if !base_path(base) {
			return Err(format!(
				"--base={base} must start and end with /, and name only nonempty path segments of letters, digits, -, ., _ or ~"
			));
		}
		Ok(Some(Self {
			assets: assets.into(),
			output: output.into(),
			base: base.into(),
		}))
	}

	/// Write the files into a directory this creates, so an export
	/// never mixes with an older one. Returns the directory written.
	pub fn run(self) -> Result<PathBuf, String> {
		let generation = Generation::load(&self.assets)?;
		let page = generation
			.files()
			.find_map(|(route, asset)| (route == "/").then_some(asset))
			.ok_or("browser generation has no page")?;
		let page = std::str::from_utf8(&page.body).map_err(|_| "browser page is not UTF-8")?;
		let page = static_page(page, &self.base)?;
		if let Some(parent) = self.output.parent().filter(|parent| !parent.as_os_str().is_empty()) {
			std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
		}
		std::fs::create_dir(&self.output).map_err(|e| format!("{}: {e}", self.output.display()))?;
		for (route, asset) in generation.files() {
			if let Some(file) = route.strip_prefix('/').filter(|file| !file.is_empty()) {
				write(&self.output, file, &asset.body)?;
			}
		}
		write(&self.output, "index.html", page.as_bytes())?;
		// The build the page compares itself with, so a tab left open on a static
		// host learns of a new deployment the way a served one does.
		write(&self.output, "ui-version", &generation.revision().body)?;
		// A deep link opens the page where this directory is the site root. Below
		// the root, the site's own 404.html must do the same.
		write(&self.output, "404.html", page.as_bytes())?;
		Ok(self.output)
	}
}

/// The page with its base element naming `base`, followed by its policies and
/// a mark that no Rooms server stands behind it, so the page asks none for
/// server routes. The source page carries the base element exactly once, ahead
/// of its scripts.
fn static_page(page: &str, base: &str) -> Result<String, String> {
	if page.matches(SOURCE_BASE).count() != 1 {
		return Err(format!("browser page must carry {SOURCE_BASE} exactly once"));
	}
	let policy = content_policy(page)?;
	let head = format!(
		r#"<base href="{base}" /><meta http-equiv="Content-Security-Policy" content="{policy}" /><meta name="referrer" content="no-referrer" /><meta name="rooms-host" content="static" />"#
	);
	Ok(page.replacen(SOURCE_BASE, &head, 1))
}

/// A base path a static host can serve and an HTML attribute can hold
/// unescaped: `/`, or `/` followed by `segment/` repeated.
fn base_path(base: &str) -> bool {
	let Some(inner) = base.strip_prefix('/') else {
		return false;
	};
	inner.is_empty()
		|| inner.strip_suffix('/').is_some_and(|inner| {
			inner.split('/').all(|segment| {
				!segment.is_empty()
					&& segment != "."
					&& segment != ".."
					&& segment
						.bytes()
						.all(|b| b.is_ascii_alphanumeric() || b"-._~".contains(&b))
			})
		})
}

fn write(root: &Path, relative: &str, body: &[u8]) -> Result<(), String> {
	let path = root.join(relative);
	if let Some(parent) = path.parent() {
		std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
	}
	std::fs::write(&path, body).map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
	use super::*;

	fn parse(args: &[&str]) -> Result<Option<StaticExport>, String> {
		StaticExport::parse(&args.iter().map(|arg| arg.to_string()).collect::<Vec<_>>())
	}

	#[test]
	fn base_paths_are_slash_bounded_segments() {
		for good in ["/", "/rooms/app/", "/a/", "/a.b_c~d-e/f/"] {
			assert!(base_path(good), "{good}");
		}
		for bad in [
			"",
			"rooms/",
			"/rooms",
			"//",
			"/rooms//app/",
			"/../",
			"/./",
			"/a b/",
			"/a\"/",
			"/é/",
		] {
			assert!(!base_path(bad), "{bad}");
		}
	}

	#[test]
	fn the_page_names_its_base_and_carries_its_policies() {
		let page = r#"<head><base href="/" /><script>x()</script><link href="page.css"></head>"#;
		let written = static_page(page, "/rooms/app/").unwrap();
		let policy = content_policy(page).unwrap();
		assert_eq!(
			written,
			format!(
				r#"<head><base href="/rooms/app/" /><meta http-equiv="Content-Security-Policy" content="{policy}" /><meta name="referrer" content="no-referrer" /><meta name="rooms-host" content="static" /><script>x()</script><link href="page.css"></head>"#
			)
		);
		assert!(policy.contains("'sha256-"), "the inline script stays allowed");
		assert!(
			!policy.contains("frame-ancestors"),
			"a meta policy cannot carry framing"
		);
		assert!(static_page("<head></head>", "/").is_err());
		assert!(static_page(&page.repeat(2), "/").is_err());
	}

	#[test]
	fn the_mode_takes_its_assets_and_an_optional_base() {
		assert!(parse(&["--prepare"]).unwrap().is_none());
		let export = parse(&["--export-static=out", "--assets=gen", "--base=/rooms/app/"])
			.unwrap()
			.unwrap();
		assert_eq!(
			(export.output.as_path(), export.assets.as_path(), export.base.as_str()),
			(Path::new("out"), Path::new("gen"), "/rooms/app/")
		);
		assert_eq!(
			parse(&["--export-static=out", "--assets=gen"]).unwrap().unwrap().base,
			"/"
		);
		for refused in [
			&["--export-static=", "--assets=gen"][..],
			&["--export-static=out"],
			&["--export-static=out", "--assets=gen", "--base=rooms"],
			&["--export-static=out", "--assets=gen", "--assets=again"],
			&["--export-static=out", "--assets=gen", "--prepared"],
		] {
			assert!(parse(refused).is_err(), "{refused:?}");
		}
	}
}
