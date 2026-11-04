"""Authoring comparison check: ADAPTER EXPECTED_SYRUP SHARED_CHECKER RUST_OUTPUT.

The build step supplies executable paths. Cap'n Proto compiles the authored
schema into a binary request; the adapter never reads source text. The shared
checker validates each accepted description through description.read/Model.init.
"""

import pathlib
import subprocess
import sys
import tempfile


def run(command, data=None):
    return subprocess.run(command, input=data, capture_output=True, timeout=20, check=False)


def require(result, label):
    if result.returncode:
        raise AssertionError(f"{label}: {result.stderr.decode(errors='replace')}")
    return result.stdout


def main():
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    adapter, expected_path, checker, rust_output = (str(pathlib.Path(arg).resolve()) for arg in sys.argv[1:])
    source = pathlib.Path(__file__).with_name("comparison.capnp").read_text()
    expected = pathlib.Path(expected_path).read_bytes()
    with tempfile.TemporaryDirectory(prefix="interface-capnp-") as temporary:
        directory = pathlib.Path(temporary)
        schema = directory / "comparison.capnp"
        (directory / "generic.capnp").write_text("@0xb98b3864eb208c7f;\nstruct Generic(T) { text @0 :Text; }\n")
        canonical = directory / "comparison.syrup"

        def compile_request(text):
            schema.write_text(text)
            return require(run(["capnp", "compile", "-o-", str(schema)]), "schema compilation")

        def accepted(text, wanted):
            request = compile_request(text)
            actual = require(run([adapter], request), "request translation")
            assert actual == wanted, "canonical description differs from independent fixture"
            canonical.write_bytes(actual)
            require(run([checker, "syrup", str(canonical)]), "shared description validation")
            return request, actual

        request, base_output = accepted(source, expected)
        ordinary_source = source.replace(' $delivery("loam.receipt")', "")
        ordinary_expected = expected.replace(b"12'loam.receipt", b"4'call").replace(b'12"loam.receipt1+', b"")
        accepted(ordinary_source, ordinary_expected)
        # The annotation controls delivery, even when a wire name spells the
        # convention name. Ordinary tells need only the values profile.
        accepted(
            "@0xf3f3de678a47c902;\n"
            "annotation module(file) :Text;\n"
            "annotation wireName(method) :Text;\n"
            "annotation delivery(method) :Text;\n"
            '$module("M");\n'
            'interface R { notify @0 () -> (value :Void) $wireName("loam.receipt") $delivery("tell"); }',
            b"<17'glowcap:interface1+{14\"glowcap.values1+}{3\"M.R<9'interface{12\"loam.receipt<6'method[]9'undefined4'tell>}>}>",
        )
        for before, after, old, new in [
            ("$maxBytes(64)", "$maxBytes(65)", b'9"max_bytes64+', b'9"max_bytes65+'),
            (
                "read @0 () -> (value :Text)",
                "read @0 () -> (value :Void)",
                b"4\"read<6'method[]6'string",
                b"4\"read<6'method[]9'undefined",
            ),
            ("read @0", "renamed @0", b"4\"read<6'method", b"7\"renamed<6'method"),
        ]:
            assert source.count(before) == 1 and expected.count(old) == 1
            accepted(source.replace(before, after), expected.replace(old, new))

        for changed, diagnostic in [
            (
                source.replace(
                    '$module("comparison");', 'annotation throws(method) :Text;\n$module("comparison");'
                ).replace("read @0 () -> (value :Text)", 'read @0 () -> (value :Text) $throws("closed")'),
                "unsupported annotation throws",
            ),
            (source.replace("name :Name", 'name :Text = "default"'), "explicit defaults"),
            (source.replace("value :Void $optional", "value :Text $nullValue"), "nullValue requires Void"),
            (source.replace("pending :Reader $pending", "pending :Text $pending"), "pending requires"),
            (source.replace('$wireName("")', '$wireName("") $direct'), "direct and wireName conflict"),
        ]:
            refused = run([adapter], compile_request(changed))
            assert refused.returncode and not refused.stdout
            assert diagnostic.encode() in refused.stderr, refused.stderr

        imported = source.replace(
            '$module("comparison");', 'using Generic = import "generic.capnp".Generic;\n$module("comparison");'
        )
        for changed in [
            imported.replace("read @0 ()", "read @0 Generic(Text)"),
            imported.replace("read @0 () -> (value :Text)", "read @0 () -> Generic(Text)"),
        ]:
            refused = run([adapter], compile_request(changed))
            assert refused.returncode and not refused.stdout, "generic method brand was erased"
            assert b"generic method brands" in refused.stderr

        # The compiler accepts these shapes; the shared semantic model refuses
        # their contradictory bounds and required-after-optional parameter list.
        for changed in [
            source.replace("$maxBytes(64)", "$maxBytes(0)"),
            source.replace('$wireName("")', "$direct"),
            source.replace("reader :Reader, pending", "reader :Reader $optional, pending"),
        ]:
            canonical.write_bytes(require(run([adapter], compile_request(changed)), "request translation"))
            assert run([checker, "syrup", str(canonical)]).returncode

        # The compiled request stays small while one module prefix expands into
        # many qualified references. Preserve a fitting case and refuse only the
        # oversized output, before allocating all repeated strings.
        long_module = source.replace('$module("comparison")', '$module("' + "m" * 4096 + '")')
        for count, fits in [(128, True), (256, False)]:
            parameters = ", ".join(f"reader{i} :Reader" for i in range(count))
            expanded = long_module.replace(
                "interface Factory {", f"interface Factory {{ wide @2 ({parameters}) -> (value :Void);"
            )
            compiled = compile_request(expanded)
            assert len(compiled) < 1024 * 1024
            translated = run([adapter], compiled)
            if fits:
                canonical.write_bytes(require(translated, "fitting expanded output"))
                require(run([checker, "syrup", str(canonical)]), "fitting expanded model")
            else:
                assert translated.returncode and not translated.stdout
                assert b"expanded output exceeds 1 MiB" in translated.stderr, translated.stderr

        for malformed in [b"", request[:-1], request + b"trailing", b"\0" * (1024 * 1024 + 1)]:
            refused = run([adapter], malformed)
            assert refused.returncode and not refused.stdout
        canonical.write_bytes(base_output)
        pathlib.Path(rust_output).parent.mkdir(parents=True, exist_ok=True)
        require(
            run([checker, "syrup", str(canonical), "rust", "comparison.Reader", "read", "authoring_read", rust_output]),
            "Rust emission from the frontend result",
        )
    print("Cap'n Proto authoring: exact corpus, three edits, refusals, and bounded input passed")


if __name__ == "__main__":
    main()
