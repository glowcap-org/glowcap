"""Run the pinned upstream suite through its own authoritative onion netlayer."""

import argparse
import importlib
import os
import sys
import time
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
UPSTREAM = HERE / "upstream"
sys.path.insert(0, str(UPSTREAM))

from contrib.syrup import Symbol
from netlayers.onion import OnionNetlayer, Socks5Proxy
from utils.ocapn_uris import OCapNPeer
from utils.test_suite import CapTPTestRunner


class PublishedOnionNetlayer(OnionNetlayer):
    """Upstream OnionNetlayer with its advertised-location precondition met.

    The pinned class returns from ADD_ONION before Tor has published the new
    descriptor, while several tests immediately hand that location to pancake
    and wait for an inbound connection. Preserve the upstream connect, accept,
    and CapTP behavior, but do not expose the instance until its own Tor can
    reach the service. The successful probe is accepted and discarded here so
    no test can mistake it for its protocol connection.
    """

    publication_budget_seconds = 180

    def __init__(self):
        super().__init__()
        try:
            self._await_publication()
        except Exception:
            self.shutdown()
            raise

    def _await_publication(self):
        deadline = time.monotonic() + self.publication_budget_seconds
        last_error = None
        while True:
            probe = Socks5Proxy(self._unix_socket_path)
            probe.settimeout(30)
            try:
                probe.connect(f"{self.location.address}.onion", self.PORT)
                self._incoming_control_socket.settimeout(30)
                incoming, _ = self._incoming_control_socket.accept()
                incoming.close()
                return
            except Exception as error:  # Tor reports unpublished services as SOCKS failures.
                last_error = error
                if time.monotonic() >= deadline:
                    raise RuntimeError(
                        "upstream onion service did not become reachable"
                    ) from last_error
                time.sleep(0.5)
            finally:
                self._incoming_control_socket.settimeout(None)
                probe.close()


def load_selected_test(runner, selector, netlayer, peer, captp_version):
    if selector is None or selector.count(".") < 3:
        return runner.loadTests(selector)
    module_name, class_name, method_name = selector.rsplit(".", 2)
    test_class = getattr(importlib.import_module(module_name), class_name)
    return unittest.TestSuite([test_class(netlayer, peer, captp_version, method_name)])


def module_matches(test_id, prefix):
    """Match discovered module ids with or without unittest's `tests.` prefix."""
    test_id = test_id.removeprefix("tests.")
    prefix = prefix.removeprefix("tests.")
    return test_id == prefix or test_id.startswith(f"{prefix}.")


def excluding_modules(suite, prefixes, excluded):
    """Return the discovered suite without tests owned by excluded modules."""
    filtered = unittest.TestSuite()
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            nested = excluding_modules(test, prefixes, excluded)
            if nested.countTestCases() != 0:
                filtered.addTest(nested)
            continue
        matches = [prefix for prefix in prefixes if module_matches(test.id(), prefix)]
        if matches:
            for prefix in matches:
                excluded[prefix] += 1
        else:
            filtered.addTest(test)
    return filtered


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("locator", help="onion OCapN peer locator to test")
    parser.add_argument("--test-module", default=None)
    parser.add_argument("--exclude-module", action="append", default=[])
    parser.add_argument("--captp-version", default="1.0")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    peer = OCapNPeer.from_uri(args.locator)
    if peer.transport != Symbol("onion"):
        parser.error("the dedicated onion runner requires an onion locator")
    if peer.hints:
        parser.error("onion locators must not carry direct-address hints")

    try:
        netlayer = PublishedOnionNetlayer()
    except (OSError, RuntimeError) as error:
        print(f"ocapn-conformance-onion: cannot start the upstream onion netlayer: {error}", file=sys.stderr)
        return 2

    try:
        os.chdir(UPSTREAM)
        runner = CapTPTestRunner(
            netlayer,
            peer,
            args.captp_version,
            verbosity=2 if args.verbose else 1,
        )
        suite = load_selected_test(
            runner,
            args.test_module,
            netlayer,
            peer,
            args.captp_version,
        )
        if args.exclude_module:
            excluded = {prefix: 0 for prefix in args.exclude_module}
            suite = excluding_modules(suite, args.exclude_module, excluded)
            missing = [prefix for prefix, count in excluded.items() if count == 0]
            if missing:
                parser.error(f"excluded modules matched no tests: {', '.join(missing)}")
            print(
                "ocapn-conformance-onion: excluded "
                + ", ".join(f"{prefix} ({count})" for prefix, count in excluded.items())
            )
        result = runner.run(suite)
        return 0 if result.wasSuccessful() else 1
    finally:
        netlayer.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
