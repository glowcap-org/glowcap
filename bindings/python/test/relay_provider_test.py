"""Managed relay route projection: validate before I/O and preserve route bytes."""

from __future__ import annotations

import json
from pathlib import Path
import unittest

from pancake import relay


DESIGNATOR = "ab" * 32
CORPUS = json.loads(
    (Path(__file__).parents[3] / "test/net/fixtures/relay_routes.json").read_text()
)


class RelayRouteTests(unittest.TestCase):
    def test_dial_url_preserves_admitted_query_bytes(self) -> None:
        route = "wss://Relay.Example.test/bridge?second=%2f&first=one"
        self.assertEqual(
            relay._dial_url(route, DESIGNATOR),
            f"{route}&rendezvous={DESIGNATOR}",
        )

    def test_route_refuses_a_noncanonical_designator(self) -> None:
        with self.assertRaises(Exception):
            relay._dial_url("wss://relay.example.test/", "AB" * 32)

    def test_route_matches_the_binding_neutral_native_corpus(self) -> None:
        self.assertEqual(CORPUS["designator"], DESIGNATOR)
        for case in CORPUS["accepted"]:
            route = case["route"]
            separator = "&" if "?" in route else "?"
            self.assertEqual(
                relay._dial_url(route, DESIGNATOR),
                f"{route}{separator}rendezvous={DESIGNATOR}",
            )
        for route in CORPUS["rejected"]:
            with self.subTest(route=route), self.assertRaises(Exception):
                relay._dial_url(route, DESIGNATOR)


if __name__ == "__main__":
    unittest.main()
