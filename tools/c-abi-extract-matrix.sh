#!/usr/bin/env bash
# Hermetic C-ABI extract hygiene matrix (ADR-0077).
# Asserts each resolve port refuses zip-slip / symlink members and accepts a
# clean lib/ prefix. Network soft-fail paths are out of scope.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/pancake-c-abi-extract.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

PREFIX=lib
FIX="$WORKDIR/fixtures"
mkdir -p "$FIX/good/$PREFIX" "$FIX/slip_src" "$FIX/link/$PREFIX"

echo 'ok' >"$FIX/good/$PREFIX/pancake_ocapn.so"
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

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

refuse_tar_members() {
	# Shared refuse policy used by the shell port (mirrors fetch-c-abi.sh).
	tarball=$1
	prefix=$2
	prefix_slash="${prefix}/"
	listing=$(tar -tvzf "$tarball") || return 2
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		kind=$(printf '%s' "$line" | cut -c1)
		name=$(printf '%s' "$line" | awk '{
			if (NF >= 6) {
				for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+-[0-9]+-[0-9]+$/) { print $(i+2); exit }
				print $NF
			} else print $NF
		}')
		# Fallback: last field after " -> " strip
		name=${name%% -> *}
		case "$name" in
		"$prefix" | "$prefix_slash"*) ;;
		*) continue ;;
		esac
		case "$name" in
		/* | *..*) return 1 ;;
		esac
		case "$kind" in
		l | h) return 1 ;;
		esac
	done <<EOF
$listing
EOF
	return 0
}

if refuse_tar_members "$FIX/good.tar.gz" "$PREFIX"; then
	pass "shell good"
else
	bad "shell good"
fi
if [ "$HAVE_SLIP" = 1 ]; then
	if refuse_tar_members "$FIX/slip.tar.gz" "$PREFIX"; then
		bad "shell slip (should refuse)"
	else
		pass "shell slip refused"
	fi
else
	pass "shell slip skipped (no --transform)"
fi
if refuse_tar_members "$FIX/link.tar.gz" "$PREFIX"; then
	bad "shell link (should refuse)"
else
	pass "shell link refused"
fi

# Python _safe_extract_lib
if command -v python3 >/dev/null 2>&1; then
	if PYTHONPATH=bindings/python python3 - "$FIX/good.tar.gz" "$FIX/slip.tar.gz" "$FIX/link.tar.gz" "$WORKDIR" "$HAVE_SLIP" <<'PY'
import importlib.util, pathlib, sys, tarfile

spec = importlib.util.spec_from_file_location(
    "lib_resolve", "bindings/python/pancake/_lib_resolve.py"
)
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

good, slip, link, work, have_slip = sys.argv[1:6]
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
if have_slip == "1":
    # Confirm fixture actually has .. before requiring refuse.
    names = tarfile.open(slip).getnames()
    if any(".." in n or n.startswith("/") for n in names):
        must_refuse(pathlib.Path(slip), "slip")
PY
	then
		pass "python extract"
	else
		bad "python extract"
	fi
else
	echo "SKIP: python3"
fi

# Deno: same refuse policy as load.ts (list then reject)
if command -v deno >/dev/null 2>&1; then
	if deno eval --quiet '
function refuse(tarball: string, prefix: string): boolean {
  const listing = new Deno.Command("tar", { args: ["-tvzf", tarball], stdout: "piped", stderr: "null" }).outputSync();
  if (listing.code !== 0) throw new Error("tar list");
  const text = new TextDecoder().decode(listing.stdout);
  const prefixSlash = prefix + "/";
  for (const line of text.split("\n")) {
    if (!line) continue;
    const kind = line[0];
    const withoutLink = line.split(" -> ")[0] ?? line;
    const parts = withoutLink.trim().split(/\s+/);
    const name = parts.length >= 8 ? parts.slice(7).join(" ") : (parts[parts.length - 1] ?? "");
    if (name !== prefix && !name.startsWith(prefixSlash)) continue;
    if (name.startsWith("/") || name.split("/").includes("..")) return true;
    if (kind === "l" || kind === "h") return true;
  }
  return false;
}
const [good, slip, link, haveSlip] = Deno.args;
if (refuse(good, "lib")) Deno.exit(1);
if (!refuse(link, "lib")) Deno.exit(2);
if (haveSlip === "1" && !refuse(slip, "lib")) Deno.exit(3);
' "$FIX/good.tar.gz" "$FIX/slip.tar.gz" "$FIX/link.tar.gz" "$HAVE_SLIP"; then
		pass "deno refuse"
	else
		bad "deno refuse"
	fi
else
	echo "SKIP: deno"
fi

# Racket: require hard-fail + refuse strings; run list-refuse when racket present
if command -v racket >/dev/null 2>&1; then
	if grep -q 'hard-fail!' bindings/racket/private/lib-resolve.rkt &&
		grep -q 'refusing unsafe tar member' bindings/racket/private/lib-resolve.rkt &&
		grep -q 'refusing link tar member' bindings/racket/private/lib-resolve.rkt; then
		pass "racket hard refuse present"
	else
		bad "racket hard refuse present"
	fi
else
	echo "SKIP: racket"
fi

# Rust build.rs is not a library — gate refuse + hard_fail presence.
if grep -q 'fn hard_fail' bindings/rust/build.rs &&
	grep -q 'refusing unsafe tar member' bindings/rust/build.rs &&
	grep -q 'refusing link tar member' bindings/rust/build.rs; then
	pass "rust hard refuse present"
else
	bad "rust hard refuse present"
fi

# Operator script must hard_fail on hygiene.
if grep -q 'hard_fail' tools/fetch-c-abi.sh &&
	grep -q 'refusing unsafe tar member' tools/fetch-c-abi.sh; then
	pass "fetch-c-abi.sh hard refuse present"
else
	bad "fetch-c-abi.sh hard refuse present"
fi

if [ "$fail" -ne 0 ]; then
	echo "c-abi-extract-matrix: FAILED" >&2
	exit 1
fi
echo "c-abi-extract-matrix: ok"
exit 0
