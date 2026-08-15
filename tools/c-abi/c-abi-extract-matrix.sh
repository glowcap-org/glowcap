#!/usr/bin/env bash
# Hermetic C-ABI extract hygiene matrix (ADR-0077).
# Executes each available resolve port's production listing validator against
# the fixture set this file builds — the fixtures are named where they are
# created, so this header does not go stale each time one is added. Network
# soft-fail paths are out of scope.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/pancake-c-abi-extract.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

# Every port and fixture this run did not exercise, named in the summary so a
# green line cannot be read as full coverage.
skipped=""

PREFIX=lib
FIX="$WORKDIR/fixtures"
mkdir -p "$FIX/good/$PREFIX" "$FIX/slip_src" "$FIX/link/$PREFIX"

echo 'ok' >"$FIX/good/$PREFIX/pancake ocapn.so"
(cd "$FIX/good" && tar -czf "$FIX/good.tar.gz" "$PREFIX")

# Zip-slip member: lib/../evil.txt (GNU tar --transform).
echo evil >"$FIX/slip_src/evil.txt"
if tar --help 2>&1 | grep -q -- '--transform'; then
	(cd "$FIX/slip_src" && tar -czf "$FIX/slip.tar.gz" --transform='s|^evil.txt|lib/../evil.txt|' evil.txt)
	HAVE_SLIP=1
else
	HAVE_SLIP=0
fi

# Symlink under lib/ (store the link itself, do not dereference).
echo 'ok' >"$FIX/link/$PREFIX/pancake_ocapn.so"
ln -s pancake_ocapn.so "$FIX/link/$PREFIX/evil.link"
(cd "$FIX/link" && tar -czf "$FIX/link.tar.gz" "$PREFIX")

# An owner blob with spaces in it. The parsers discriminate GNU from BSD by
# fixed field positions, and the owner/group column is attacker-chosen text: put
# whitespace in it and one field becomes several, so every later column shifts
# and the member name is reconstructed starting three fields late. The name then
# matches no prefix and the member is skipped before its kind is tested, while
# tar still extracts it under its real name. Seven owner tokens put the size,
# month, day and clock slots where the BSD shape expects them; the trailing
# `0000` satisfies the four-digit-year alternative.
if (cd "$FIX/link" && tar -czf "$FIX/adversarial.tar.gz" \
	--owner='0 x' --group='z y 0 Jan 1 0000' "$PREFIX") 2>/dev/null; then
	:
else
	(cd "$FIX/link" && tar -czf "$FIX/adversarial.tar.gz" \
		--uname '0 x' --gname 'z y 0 Jan 1 0000' "$PREFIX")
fi

# A regular file whose own name contains " -> ", the separator tar prints
# before a link's target. A parser that cuts the line there checks `lib/x` and
# never sees the traversal in the name tar would actually extract.
UNSAFE="$FIX/link.tar.gz $FIX/adversarial.tar.gz"
if [ "$HAVE_SLIP" = 1 ]; then
	(cd "$FIX/slip_src" && tar -czf "$FIX/arrow.tar.gz" \
		--transform='s|^evil.txt|lib/x -> ../../evil|' evil.txt)
	UNSAFE="$UNSAFE $FIX/arrow.tar.gz"
fi

# The same symlink, in an archive built with `tar -czf x .`, so every member
# is stored as `./lib/…`. A port that does not normalize that prefix matches
# nothing and passes the archive without ever inspecting the link.
tar -czf "$FIX/dotslash.tar.gz" -C "$FIX/link" .
UNSAFE="$UNSAFE $FIX/dotslash.tar.gz"

# A symlink named exactly the prefix, so the whole library directory *is* the
# link. Its printed name is `lib -> /target`, which matches neither `lib` nor
# `lib/…`, so a port that filters by prefix before checking the kind skips the
# one member that matters and accepts the archive. Extraction then writes a
# link where the loader expects a directory, and the next `dlopen` reads
# whatever it points at.
mkdir -p "$FIX/rootlink"
ln -s /tmp "$FIX/rootlink/$PREFIX"
(cd "$FIX/rootlink" && tar --no-recursion -czf "$FIX/rootlink.tar.gz" "$PREFIX")
UNSAFE="$UNSAFE $FIX/rootlink.tar.gz"

# The same prefix-named symlink stored as `./lib`, so the two name repairs have
# to compose: strip the `./` first, then the link's ` -> target` tail. A port
# that does them in the other order compares `./lib` against `lib` and skips.
mkdir -p "$FIX/dotslashrootlink"
ln -s /tmp "$FIX/dotslashrootlink/$PREFIX"
tar -czf "$FIX/dotslashrootlink.tar.gz" -C "$FIX/dotslashrootlink" .
UNSAFE="$UNSAFE $FIX/dotslashrootlink.tar.gz"

# A prefix-named symlink whose *target* contains the separator, printed as
# `lib -> /tmp -> x`. The tail strip has to cut at the first separator; cutting
# at the last leaves `lib -> /tmp`, which matches no prefix and is skipped.
mkdir -p "$FIX/arrowtarget"
ln -s '/tmp -> x' "$FIX/arrowtarget/$PREFIX"
(cd "$FIX/arrowtarget" && tar --no-recursion -czf "$FIX/arrowtarget.tar.gz" "$PREFIX")
UNSAFE="$UNSAFE $FIX/arrowtarget.tar.gz"

# The same shape as a hard link, which tar prints with the other separator:
# `lib link to real`, not `lib -> real`. A strip that knows only the symlink
# spelling leaves this one matching no prefix, so it is skipped before the kind
# test — the identical evasion, through the other half of the same condition.
mkdir -p "$FIX/roothard"
echo 'ok' >"$FIX/roothard/real"
ln "$FIX/roothard/real" "$FIX/roothard/$PREFIX"
(cd "$FIX/roothard" && tar -czf "$FIX/roothard.tar.gz" real "$PREFIX")
UNSAFE="$UNSAFE $FIX/roothard.tar.gz"

# A member that is neither a regular file, a directory, nor a link. Every port
# refuses it; skipping it instead would extract partially.
mkdir -p "$FIX/fifo/$PREFIX"
echo 'ok' >"$FIX/fifo/$PREFIX/pancake_ocapn.so"
if mkfifo "$FIX/fifo/$PREFIX/evil.fifo" 2>/dev/null; then
	(cd "$FIX/fifo" && tar -czf "$FIX/fifo.tar.gz" "$PREFIX")
	UNSAFE="$UNSAFE $FIX/fifo.tar.gz"
	HAVE_FIFO=1
else
	HAVE_FIFO=0
	echo "SKIP: fifo fixture (no mkfifo)"
	skipped="$skipped fifo"
fi

# Counted, not asserted. The summary at the end used to name a fixed number of
# validators and extracts, which on a runner missing racket or rustc printed a
# count and then listed two of them as skipped, in one line.
validators=0
extracts=0
hostile_env=0
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

. tools/c-abi/archive-hygiene.sh

if archive_hygiene_check "$FIX/good.tar.gz" "$PREFIX"; then
	validators=$((validators + 1))
	pass "shell good"
else
	bad "shell good"
fi
if [ "$HAVE_SLIP" = 1 ]; then
	if archive_hygiene_check "$FIX/slip.tar.gz" "$PREFIX"; then
		bad "shell slip (should refuse)"
	else
		pass "shell slip refused"
	fi
else
	echo "SKIP: slip and arrow fixtures (tar has no --transform)"
	skipped="$skipped slip+arrow"
fi
for unsafe in $UNSAFE; do
	label=$(basename "$unsafe" .tar.gz)
	if archive_hygiene_check "$unsafe" "$PREFIX"; then
		bad "shell $label (should refuse)"
	else
		pass "shell $label refused"
	fi
done

# A hostile `TAR_OPTIONS` in the environment can hide a member from the
# listing that the extract would still write. The validator must not see a
# different archive than the extract does. Only the shell port both invokes
# tar and owns its parser, so it is the one directly testable here; the other
# ports' invocations live in their importers and are held by source-check.
if TAR_OPTIONS='--exclude=lib/evil.link' archive_hygiene_check "$FIX/link.tar.gz" "$PREFIX"; then
	bad "shell TAR_OPTIONS (a hidden member should still be refused)"
else
	hostile_env=$((hostile_env + 1))
	pass "shell TAR_OPTIONS ignored"
fi

# Python _safe_extract_lib
if command -v python3 >/dev/null 2>&1; then
	if PYTHONPATH=bindings/python python3 - "$FIX/good.tar.gz" "$FIX/slip.tar.gz" "$FIX/link.tar.gz" "$WORKDIR" "$HAVE_SLIP" "$FIX/arrow.tar.gz" "$HAVE_FIFO" "$FIX/fifo.tar.gz" "$FIX/dotslash.tar.gz" "$FIX/rootlink.tar.gz" "$FIX/adversarial.tar.gz" "$FIX/dotslashrootlink.tar.gz" "$FIX/arrowtarget.tar.gz" "$FIX/roothard.tar.gz" <<'PY'
import importlib.util, pathlib, sys, tarfile

spec = importlib.util.spec_from_file_location(
    "lib_resolve", "bindings/python/pancake/_lib_resolve.py"
)
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

good, slip, link, work, have_slip, arrow, have_fifo, fifo, dotslash, rootlink, adversarial, dsroot, arrowtarget, roothard = sys.argv[1:15]
work = pathlib.Path(work)
stage = work / "py-good"
stage.mkdir()
mod._safe_extract_lib(pathlib.Path(good), stage, prefix="lib")
assert (stage / "lib").is_dir()

def must_refuse(path: pathlib.Path, label: str) -> None:
    s = work / f"py-{label}"
    s.mkdir(exist_ok=True)
    try:
        mod._safe_extract_lib(path, s, prefix="lib")
    except OSError:
        return
    raise SystemExit(f"accepted {label}")

must_refuse(pathlib.Path(link), "link")
must_refuse(pathlib.Path(dotslash), "dotslash")
must_refuse(pathlib.Path(rootlink), "rootlink")
must_refuse(pathlib.Path(adversarial), "adversarial")
must_refuse(pathlib.Path(dsroot), "dotslashrootlink")
must_refuse(pathlib.Path(arrowtarget), "arrowtarget")
must_refuse(pathlib.Path(roothard), "roothard")
if have_fifo == "1":
    must_refuse(pathlib.Path(fifo), "fifo")
if have_slip == "1":
    # Confirm fixture actually has .. before requiring refuse.
    names = tarfile.open(slip).getnames()
    if any(".." in n or n.startswith("/") for n in names):
        must_refuse(pathlib.Path(slip), "slip")
    must_refuse(pathlib.Path(arrow), "arrow")
PY
	then
		extracts=$((extracts + 1))
		validators=$((validators + 1))
		pass "python extract"
	else
		bad "python extract"
	fi
else
	echo "SKIP: python3"
	skipped="$skipped python3"
fi

# Deno, the production loader itself: run `safeExtractPrefix` — its own listing
# call, its own environment, its own extract — under a hostile TAR_OPTIONS that
# would hide the symlink from a tar inheriting it.
if command -v deno >/dev/null 2>&1; then
	mkdir -p "$WORKDIR/loader-clean"
	if TAR_OPTIONS='--exclude=lib/evil.link --exclude=lib/pancake ocapn.so' deno eval --quiet '
import { safeExtractPrefix } from "./bindings/ts/runtime/internal/ffi/load.ts";
const [unsafeTar, cleanTar, rootTar, stage] = Deno.args;

// The listing side: a member the hostile options would hide must still be
// seen and refused.
try {
  safeExtractPrefix(unsafeTar, stage, "lib");
  console.error("production loader accepted an archive with a hidden symlink");
  Deno.exit(1);
} catch (err) {
  if (!String(err).includes("refusing")) {
    console.error("wrong failure:", err);
    Deno.exit(2);
  }
}

// The whole library directory as a symlink. This is the member whose printed
// name evades a prefix test, so it is the one that has to be refused by the
// production path rather than only by the parser.
try {
  safeExtractPrefix(rootTar, stage, "lib");
  console.error("production loader accepted a symlink named lib");
  Deno.exit(4);
} catch (err) {
  if (!String(err).includes("refusing")) {
    console.error("wrong failure for rootlink:", err);
    Deno.exit(5);
  }
}

// The extract side, which the refusal above never reaches: a clean archive
// must extract completely, so the same options cannot drop a member on the
// way out either.
safeExtractPrefix(cleanTar, stage, "lib");
const extracted = Deno.readDirSync(`${stage}/lib`);
for (const entry of extracted) {
  if (entry.name === "pancake ocapn.so") Deno.exit(0);
}
console.error("extraction dropped a member under hostile TAR_OPTIONS");
Deno.exit(3);
' "$FIX/link.tar.gz" "$FIX/good.tar.gz" "$FIX/rootlink.tar.gz" "$WORKDIR/loader-clean"; then
		extracts=$((extracts + 1))
		hostile_env=$((hostile_env + 1))
		pass "deno loader refuses under hostile TAR_OPTIONS"
	else
		bad "deno loader refuses under hostile TAR_OPTIONS"
	fi
else
	echo "SKIP: deno loader seam"
	skipped="$skipped deno-loader"
fi

# Deno: same refuse policy as load.ts (list then reject)
if command -v deno >/dev/null 2>&1; then
	if deno eval --quiet '
import { archiveListingViolation } from "./bindings/ts/runtime/internal/ffi/archive_hygiene.ts";
function violation(tarball: string): string | null {
  const listing = new Deno.Command("tar", {
    args: ["--numeric-owner", "-tvzf", tarball],
    stdout: "piped",
    stderr: "null",
    env: { LC_ALL: "C" },
  }).outputSync();
  if (listing.code !== 0) throw new Error("tar list");
  const text = new TextDecoder().decode(listing.stdout);
  return archiveListingViolation(text, "lib");
}
const [good, slip, haveSlip, ...unsafe] = Deno.args;
if (violation(good) !== null) Deno.exit(1);
if (haveSlip === "1" && violation(slip) === null) Deno.exit(2);
for (const path of unsafe) {
  if (violation(path) === null) {
    console.error(`accepted unsafe archive: ${path}`);
    Deno.exit(3);
  }
}
' "$FIX/good.tar.gz" "$FIX/slip.tar.gz" "$HAVE_SLIP" $UNSAFE; then
		validators=$((validators + 1))
		pass "deno refuse"
	else
		bad "deno refuse"
	fi
else
	echo "SKIP: deno"
	skipped="$skipped deno"
fi

# Racket: execute the production validator when the runtime is available.
if command -v racket >/dev/null 2>&1; then
	if racket tools/c-abi/racket-archive-hygiene-check.rkt \
		"$FIX/good.tar.gz" "$FIX/slip.tar.gz" "$HAVE_SLIP" $UNSAFE; then
		validators=$((validators + 1))
		pass "racket refuse"
	else
		bad "racket refuse"
	fi
else
	echo "SKIP: racket"
	skipped="$skipped racket"
fi

# Rust: compile a tiny runner around the exact module build.rs imports.
if command -v rustc >/dev/null 2>&1; then
	if rustc tools/c-abi/rust-archive-hygiene-check.rs -o "$WORKDIR/rust-archive-hygiene-check" &&
		"$WORKDIR/rust-archive-hygiene-check" \
			"$FIX/good.tar.gz" "$FIX/slip.tar.gz" "$HAVE_SLIP" $UNSAFE; then
		validators=$((validators + 1))
		pass "rust refuse"
	else
		bad "rust refuse"
	fi
else
	echo "SKIP: rustc"
	skipped="$skipped rustc"
fi

if [ "$fail" -ne 0 ]; then
	echo "c-abi-extract-matrix: FAILED" >&2
	exit 1
fi
# Name what ran, not what one could infer. Three ports run their listing
# validator only; two run a real extract. A line claiming "every port, every
# fixture" would read as coverage the matrix does not have, which is the
# failure this whole file exists to prevent.
summary="$validators listing validators, $extracts extracts, $hostile_env hostile-TAR_OPTIONS arms"
if [ -n "$skipped" ]; then
	echo "c-abi-extract-matrix: ok ($summary), but NOT exercised here:$skipped"
else
	echo "c-abi-extract-matrix: ok ($summary)"
fi
exit 0
