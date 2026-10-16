"""ocapn-conformance-next child runner. Policy comes from the validated manifest.

The build owns peer supervision and the per-module deadline. Deferred modules
exit 77 and name their decision, pending work fails, and unittest skips fail.
"""
import argparse
import json
import secrets
from pathlib import Path
import subprocess
import sys
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "upstream"))

from utils.ocapn_uris import OCapNPeer
from utils.test_suite import CapTPTestLoader
from next_wire import NextNetlayer


class NextTestLoader(CapTPTestLoader):
    def loadTestsFromTestCase(self, case_class):
        if hasattr(case_class, "make_valid_handoff"):
            # The pinned suite defaults to a seven-byte gift ID. Next requires
            # 32 random bytes. Change the fixture before signing, retaining
            # every upstream assertion and every deliberate certificate mutation.
            class CanonicalGift(case_class):
                def make_valid_handoff(self, gift_id=None):
                    return super().make_valid_handoff(secrets.token_bytes(32) if gift_id is None else gift_id)
            CanonicalGift.__name__ = case_class.__name__
            CanonicalGift.__qualname__ = case_class.__qualname__
            CanonicalGift.__module__ = case_class.__module__
            case_class = CanonicalGift
        return super().loadTestsFromTestCase(case_class)


def suite_policy(plan, module):
    # Shared setup is executable coverage too. Reviewing only the selected test
    # module would let an unimplemented new helper disappear behind a green run.
    pending = [row["name"] for row in plan.values() if row["state"] == "pending"]
    if pending:
        raise RuntimeError(f"PENDING next suite sources: {', '.join(pending)}")
    if module == "next_cases":
        return None
    source = module.replace(".", "/") + ".py"
    row = plan[source]
    if row["state"] == "deferred":
        return f"DEFERRED {module}: {row['decision']}"
    if row["state"] != "adopted":
        raise RuntimeError(f"invalid adoption state for {source}")
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("--module", required=True)
    parser.add_argument("--adoption-tool", required=True)
    args = parser.parse_args()
    checked = subprocess.run([args.adoption_tool, "--next-suite-plan"], check=True,
                             capture_output=True, text=True, timeout=10)
    plan = {row["name"]: row for row in json.loads(checked.stdout)}
    deferred = suite_policy(plan, args.module)
    if deferred:
        print(deferred)
        return 77
    netlayer = NextNetlayer()
    try:
        loader = NextTestLoader(netlayer, OCapNPeer.from_uri(args.url), "1.0")
        tests = loader.loadTestsFromName(args.module)
        if tests.countTestCases() == 0:
            raise RuntimeError("empty next conformance module")
        result = unittest.TextTestRunner(verbosity=2, failfast=True).run(tests)
        return 0 if result.wasSuccessful() and not result.skipped else 1
    finally:
        netlayer.shutdown()


if __name__ == "__main__":
    sys.exit(main())
