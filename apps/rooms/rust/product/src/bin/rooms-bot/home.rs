//! The bot's home: `home/` in the bot directory, the one place the agent
//! keeps across every conversation and restart. The bot creates it and never
//! rewrites or removes it, so `/reset`, letting a conversation go, and a new
//! link leave it as the agent left it. `home/memory/` holds the agent's
//! memories, one small file each with a one-line summary first. Every turn's
//! prompt lists them, newest first, and the bot builds that listing itself so
//! no file in the home is shared bookkeeping that two turns could overwrite.
use super::error::Error;
use nix::{
	dir::Dir,
	fcntl::{AtFlags, OFlag},
	sys::stat::{FileStat, Mode, SFlag, fstatat},
};
use std::{
	ffi::{CStr, CString},
	fs::File,
	io::Read,
	os::fd::OwnedFd,
	path::{Path, PathBuf},
	time::{Duration, SystemTime},
};

const DIRECTORY: &str = "home";
const MEMORY: &str = "memory";
/// The per-turn variable that names the home, beside the bot directory and
/// the conversation.
pub const TURN_HOME: &str = "GLOWCAP_ROOMS_TURN_HOME";
/// Memories one turn's listing names. Older ones are counted, not named.
pub const MAX_LISTED: usize = 64;
/// Bytes of file names and summaries one turn's listing holds.
pub const MAX_LISTING_BYTES: usize = 8_192;
/// Bytes kept of one summary. A longer first line keeps its beginning.
pub const MAX_SUMMARY_BYTES: usize = 200;
/// Bytes read from a memory to find its first line: enough to tell that a
/// line runs past the bound, and to finish the character it is cut in.
const READ_BYTES: u64 = MAX_SUMMARY_BYTES as u64 + 4;
const CUT: &str = " [cut]";

/// The home inside the bot directory `root`.
pub fn path(root: &Path) -> PathBuf {
	root.join(DIRECTORY)
}

/// Create the home and its memory directory, keeping whatever is there.
pub fn create(root: &Path) -> Result<PathBuf, Error> {
	let home = path(root);
	std::fs::create_dir_all(home.join(MEMORY)).map_err(Error::io("creating the bot's home"))?;
	Ok(home)
}

/// One memory as a turn lists it. `summary` is `None` for a file the bot
/// could not read as text, which is listed by name only.
#[derive(Debug, PartialEq, Eq)]
pub struct Memory {
	pub file: String,
	pub summary: Option<String>,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Listing {
	/// Newest first.
	pub memories: Vec<Memory>,
	/// Memories past either bound, which the turn is told the number of.
	pub unlisted: usize,
	/// Memories whose file names are not text free of control characters.
	/// The listing leaves them out, so no name reaches the prompt in a form
	/// other than its own, and the turn logs how many.
	pub unnamed: usize,
}

struct Entry {
	modified: SystemTime,
	file: String,
	name: CString,
	regular: bool,
}

/// `home/memory/`, reached without following a link at the home or at the
/// memory directory, so a link there cannot point the listing at the rest of
/// the bot directory or anywhere else.
fn memory(root: &Path) -> Option<OwnedFd> {
	let directory = OFlag::O_RDONLY | OFlag::O_CLOEXEC | OFlag::O_NOFOLLOW | OFlag::O_DIRECTORY;
	let home = nix::fcntl::open(&path(root), directory, Mode::empty()).ok()?;
	nix::fcntl::openat(&home, MEMORY, directory, Mode::empty()).ok()
}

fn kind(stat: &FileStat) -> SFlag {
	SFlag::from_bits_truncate(stat.st_mode) & SFlag::S_IFMT
}

/// Call `each` with every entry in `home/memory/` that counts as a memory:
/// everything but a directory, described without following a link. Returns
/// the memory directory, for opening the entries. A directory that cannot be
/// read yields none, because a listing never fails a turn.
fn scan(root: &Path, mut each: impl FnMut(&CStr, &FileStat)) -> Option<OwnedFd> {
	let memory = memory(root)?;
	let mut entries = Dir::from_fd(memory.try_clone().ok()?).ok()?;
	for entry in entries.iter().flatten() {
		let name = entry.file_name();
		if name == c"." || name == c".." {
			continue;
		}
		match fstatat(&memory, name, AtFlags::AT_SYMLINK_NOFOLLOW) {
			Ok(stat) if kind(&stat) != SFlag::S_IFDIR => each(name, &stat),
			_ => {}
		}
	}
	Some(memory)
}

/// How many memories the home holds, for `bot status`.
pub fn count(root: &Path) -> usize {
	let mut total = 0;
	scan(root, |_, _| total += 1);
	total
}

fn modified(stat: &FileStat) -> SystemTime {
	match (u64::try_from(stat.st_mtime), u32::try_from(stat.st_mtime_nsec)) {
		(Ok(seconds), Ok(nanos)) => SystemTime::UNIX_EPOCH + Duration::new(seconds, nanos),
		_ => SystemTime::UNIX_EPOCH,
	}
}

fn newest_first(kept: &mut Vec<Entry>) {
	kept.sort_by(|a, b| b.modified.cmp(&a.modified).then_with(|| a.file.cmp(&b.file)));
	kept.truncate(MAX_LISTED);
}

/// The listing for one turn, never failing. A symlink, a special file, and a
/// file that is not text are named without a summary, and a file whose name
/// is not plain text is counted in [`Listing::unnamed`]. The scan keeps at
/// most twice [`MAX_LISTED`] entries at a time, however many the directory
/// holds.
pub fn listing(root: &Path) -> Listing {
	let mut total = 0;
	let mut unnamed = 0;
	let mut kept = Vec::new();
	let Some(memory) = scan(root, |name, stat| {
		let Some(file) = name.to_str().ok().filter(|file| !file.chars().any(char::is_control)) else {
			unnamed += 1;
			return;
		};
		total += 1;
		kept.push(Entry {
			modified: modified(stat),
			file: file.to_owned(),
			name: name.to_owned(),
			regular: kind(stat) == SFlag::S_IFREG,
		});
		if kept.len() >= 2 * MAX_LISTED {
			newest_first(&mut kept);
		}
	}) else {
		return Listing::default();
	};
	newest_first(&mut kept);
	let mut listing = Listing::default();
	let mut bytes = 0;
	for entry in kept {
		let summary = entry.regular.then(|| summary(&memory, &entry.name)).flatten();
		let size = entry.file.len() + summary.as_ref().map_or(0, String::len);
		if bytes + size > MAX_LISTING_BYTES {
			break;
		}
		bytes += size;
		listing.memories.push(Memory {
			file: entry.file,
			summary,
		});
	}
	listing.unlisted = total - listing.memories.len();
	listing.unnamed = unnamed;
	listing
}

/// The first line of the regular file `name` in `memory`, or `None` when it
/// cannot be opened without following a link or blocking, or is not text. A
/// line past [`MAX_SUMMARY_BYTES`] is cut on a character boundary and marked.
fn summary(memory: &OwnedFd, name: &CStr) -> Option<String> {
	let flags = OFlag::O_RDONLY | OFlag::O_CLOEXEC | OFlag::O_NOFOLLOW | OFlag::O_NONBLOCK;
	let file = File::from(nix::fcntl::openat(memory, name, flags, Mode::empty()).ok()?);
	if !file.metadata().ok()?.is_file() {
		return None;
	}
	first_line(file)
}

fn first_line(file: File) -> Option<String> {
	let mut prefix = Vec::new();
	file.take(READ_BYTES).read_to_end(&mut prefix).ok()?;
	let (line, whole) = match prefix.iter().position(|&byte| byte == b'\n') {
		Some(end) => (&prefix[..end], true),
		None => (&prefix[..], (prefix.len() as u64) < READ_BYTES),
	};
	if line.contains(&0) {
		return None;
	}
	let mut text = match std::str::from_utf8(line) {
		Ok(text) => text.to_owned(),
		// The read may end inside a character, which the cut below drops.
		Err(error) if !whole && error.error_len().is_none() => {
			String::from_utf8_lossy(&line[..error.valid_up_to()]).into_owned()
		}
		Err(_) => return None,
	};
	let cut = !whole || text.len() > MAX_SUMMARY_BYTES;
	text.truncate(text.floor_char_boundary(MAX_SUMMARY_BYTES));
	let mut text = text.trim().to_owned();
	if text.is_empty() {
		return None;
	}
	if cut {
		text.push_str(CUT);
	}
	Some(text)
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_testing::scratch::Scratch;

	fn home() -> (Scratch, PathBuf) {
		let dir = Scratch::create("bot-home");
		let memory = create(&dir).unwrap().join(MEMORY);
		(dir, memory)
	}

	fn write(memory: &Path, name: &str, bytes: &[u8], age: u64) {
		let path = memory.join(name);
		std::fs::write(&path, bytes).unwrap();
		let file = File::options().write(true).open(&path).unwrap();
		file.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000 - age))
			.unwrap();
	}

	#[test]
	fn memories_are_listed_newest_first_by_their_first_line() {
		let (dir, memory) = home();
		write(&memory, "old.md", b"Ann prefers short answers\nmore\n", 20);
		write(&memory, "new.md", b"  The build runs with zig build check  \r\n", 10);
		std::fs::create_dir(memory.join("drafts")).unwrap();
		assert_eq!(
			listing(&dir),
			Listing {
				memories: vec![
					Memory {
						file: "new.md".into(),
						summary: Some("The build runs with zig build check".into())
					},
					Memory {
						file: "old.md".into(),
						summary: Some("Ann prefers short answers".into())
					},
				],
				unlisted: 0,
				unnamed: 0,
			}
		);
		assert_eq!(count(&dir), 2, "a directory is not a memory");
	}

	#[test]
	fn a_file_whose_name_is_not_plain_text_is_counted_and_never_named() {
		use std::os::unix::ffi::OsStrExt;
		let (dir, memory) = home();
		write(&memory, "plain.md", b"kept\n", 0);
		write(&memory, "line\nbreak.md", b"a\n", 1);
		write(&memory, "bell\u{7}.md", b"a\n", 2);
		std::fs::write(memory.join(std::ffi::OsStr::from_bytes(b"not-utf8-\xff.md")), b"a\n").unwrap();
		let listed = listing(&dir);
		let named: Vec<_> = listed.memories.iter().map(|memory| memory.file.as_str()).collect();
		assert_eq!(named, ["plain.md"]);
		assert_eq!((listed.unlisted, listed.unnamed), (0, 3));
	}

	#[test]
	fn a_long_first_line_is_cut_on_a_character_boundary_and_marked() {
		let (dir, memory) = home();
		let long = "é".repeat(MAX_SUMMARY_BYTES);
		write(&memory, "long.md", long.as_bytes(), 0);
		write(&memory, "short.md", "é".repeat(MAX_SUMMARY_BYTES / 2).as_bytes(), 1);
		let memories = listing(&dir).memories;
		let summary = memories[0].summary.as_deref().unwrap();
		assert!(summary.ends_with(CUT), "{summary}");
		assert_eq!(summary.len(), MAX_SUMMARY_BYTES + CUT.len());
		assert_eq!(
			memories[1].summary.as_deref(),
			Some(&*"é".repeat(MAX_SUMMARY_BYTES / 2))
		);
	}

	#[test]
	fn a_file_that_is_not_text_or_not_regular_is_listed_by_name_only() {
		let (dir, memory) = home();
		write(&memory, "binary", b"\xff\xfe\x00\x01", 0);
		write(&memory, "nul", b"a\0b\n", 1);
		write(&memory, "empty", b"", 2);
		write(&memory, "target.md", b"secret outside\n", 3);
		std::os::unix::fs::symlink(memory.join("target.md"), memory.join("link")).unwrap();
		let outside = dir.join("outside.md");
		std::fs::write(&outside, "outside the home\n").unwrap();
		std::os::unix::fs::symlink(&outside, memory.join("away")).unwrap();
		nix::unistd::mkfifo(&memory.join("fifo"), nix::sys::stat::Mode::S_IRWXU).unwrap();
		let listed = listing(&dir);
		for name in ["binary", "nul", "empty", "link", "away", "fifo"] {
			let memory = listed.memories.iter().find(|memory| memory.file == name).unwrap();
			assert_eq!(memory.summary, None, "{name}");
		}
		assert_eq!(listed.memories.len(), 7);
	}

	#[test]
	fn the_listing_holds_both_bounds_and_counts_the_rest() {
		let (dir, memory) = home();
		for at in 0..MAX_LISTED * 3 {
			write(
				&memory,
				&format!("m{at:03}.md"),
				format!("memory {at}\n").as_bytes(),
				at as u64,
			);
		}
		let listed = listing(&dir);
		assert_eq!(listed.memories.len(), MAX_LISTED);
		assert_eq!(listed.memories[0].file, "m000.md", "the newest comes first");
		assert_eq!(listed.unlisted, MAX_LISTED * 2);

		let (dir, memory) = home();
		let line = "x".repeat(MAX_SUMMARY_BYTES - 1);
		for at in 0..MAX_LISTED {
			write(&memory, &format!("{at:02}"), format!("{line}\n").as_bytes(), at as u64);
		}
		let listed = listing(&dir);
		let bytes: usize = listed
			.memories
			.iter()
			.map(|memory| memory.file.len() + memory.summary.as_ref().map_or(0, String::len))
			.sum();
		assert!(
			bytes <= MAX_LISTING_BYTES && bytes + 2 + line.len() > MAX_LISTING_BYTES,
			"{bytes}"
		);
		assert_eq!(listed.memories.len() + listed.unlisted, MAX_LISTED);
		assert!(listed.unlisted > 0);
	}

	#[test]
	fn a_home_or_memory_directory_that_is_a_link_lists_nothing() {
		let (dir, memory) = home();
		write(&memory, "kept.md", b"a memory\n", 0);
		let elsewhere = Scratch::create("bot-home-elsewhere");
		std::fs::create_dir_all(elsewhere.join("memory")).unwrap();
		std::fs::write(elsewhere.join("session.link"), "the access link\n").unwrap();
		std::fs::write(elsewhere.join("memory/session.link"), "the access link\n").unwrap();
		std::fs::rename(&memory, dir.join("home/kept")).unwrap();
		std::os::unix::fs::symlink(&*elsewhere, &memory).unwrap();
		assert_eq!(listing(&dir), Listing::default(), "a linked memory directory was read");
		assert_eq!(count(&dir), 0);
		std::fs::remove_file(&memory).unwrap();
		std::fs::rename(dir.join("home"), dir.join("home.real")).unwrap();
		std::os::unix::fs::symlink(&*elsewhere, dir.join("home")).unwrap();
		assert_eq!(listing(&dir), Listing::default(), "a linked home was read");
		assert_eq!(count(&dir), 0);
	}

	#[test]
	fn a_missing_home_lists_nothing() {
		let dir = Scratch::create("bot-home-missing");
		assert_eq!(listing(&dir), Listing::default());
		assert_eq!(count(&dir), 0);
	}
}
