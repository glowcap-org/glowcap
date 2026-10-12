// Internal archive-listing validation shared by the loader and its gate.
// Accept only the two `LC_ALL=C tar -tvzf` layouts used by GNU and BSD tar;
// unknown layouts fail closed instead of guessing where the member name starts.

const isoDate = /^\d{4}-\d{2}-\d{2}$/;
const month = /^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)$/;
const digits = /^\d+$/;
const clockOrYear = /^(\d{2}:\d{2}(:\d{2})?|\d{4})$/;
// The owner columns must be numeric. The listing is taken with
// `--numeric-owner`, and this refuses one that is not: a tar that
// ignores the flag, or an owner name containing a space, turns one field into
// several and shifts every later column. That shift moves where the member name
// begins, so the name reconstructs wrong, misses the prefix test, and the member
// is skipped before its kind is ever checked.
const numericOwner = /^\d+\/\d+$/;

// The whole line is parsed, including any " -> target" tail. Stripping that
// tail first would truncate a regular file whose own name contains " -> ",
// and the traversal check would then run on a prefix of the name tar
// extracts. Link entries need no strip: they are refused for their
// kind, whatever their name parses to.
function memberName(line: string): { kind: string; name: string } | null {
	const parts = line.trim().split(/\s+/);
	let start = -1;
	// GNU tar: mode owner/group size YYYY-MM-DD HH:MM name...
	if (
		parts.length >= 6 && numericOwner.test(parts[1] ?? "") &&
		digits.test(parts[2] ?? "") &&
		isoDate.test(parts[3] ?? "") && clockOrYear.test(parts[4] ?? "")
	) {
		start = 5;
		// BSD tar: mode links owner group size Mon DD HH:MM name...
	} else if (
		parts.length >= 9 && digits.test(parts[1] ?? "") &&
		digits.test(parts[2] ?? "") && digits.test(parts[3] ?? "") &&
		digits.test(parts[4] ?? "") && month.test(parts[5] ?? "") &&
		digits.test(parts[6] ?? "") && clockOrYear.test(parts[7] ?? "")
	) {
		start = 8;
	}
	if (start < 0 || start >= parts.length) return null;
	return { kind: line[0] ?? "", name: parts.slice(start).join(" ") };
}

/** Return the hard-failure reason, or null when every selected member is safe. */
export function archiveListingViolation(
	listing: string,
	prefix: string,
): string | null {
	const prefixSlash = `${prefix}/`;
	for (const line of listing.split("\n")) {
		if (line.length === 0) continue;
		const member = memberName(line);
		if (member === null) {
			return `unrecognized tar listing format (need GNU or BSD tar; got: ${line})\n` +
				"  install GNU tar, or set GLOWCAP_LIB_DIR to a directory you extracted yourself";
		}
		const { kind } = member;
		// `tar -czf x .` stores every member as `./lib/…`. Without this the
		// prefix test below matches nothing and the whole archive passes
		// unexamined, which is not the same as passing.
		const raw = member.name.startsWith("./") ? member.name.slice(2) : member.name;
		// A link's printed name carries its target: `lib -> /etc`. Strip that tail
		// for the prefix test, and only for a link, so a link *named* the prefix is
		// still recognized as being under it. Without this the reconstructed name
		// matches neither `lib` nor `lib/…`, the member is skipped before the kind
		// test, and a symlink named exactly `lib` is extracted as the library
		// directory. A regular file whose own name contains " -> " must keep its
		// whole name, which is why the strip is conditioned on the kind.
		const separator = kind === "l" ? " -> " : kind === "h" ? " link to " : null;
		const name = separator === null ? raw : (raw.split(separator)[0] ?? raw);
		if (name !== prefix && !name.startsWith(prefixSlash)) continue;
		if (kind !== "-" && kind !== "d") {
			return `refusing non-file tar member: ${name}`;
		}
		if (name.startsWith("/") || name.split("/").includes("..")) {
			return `refusing unsafe tar member: ${name}`;
		}
	}
	return null;
}
