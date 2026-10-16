"""Fixture and policy regression tests, owned by ocapn-conformance-next."""
import unittest
from unittest.mock import patch

from next_runner import suite_policy
from next_wire import NextSocket, Record, Symbol, types


def row(state="adopted"):
    return {"name": "tests/op_deliver.py", "state": state, "decision": "docs/decision.md"}


class PolicyTests(unittest.TestCase):
    def test_shared_pending_sources_block_every_execution(self):
        plan = {"tests/op_deliver.py": row(), "utils/captp.py": {
            "name": "utils/captp.py", "state": "pending", "decision": "docs/decision.md"}}
        for module in ("tests.op_deliver", "next_cases"):
            with self.assertRaisesRegex(RuntimeError, "PENDING.*utils/captp.py"):
                suite_policy(plan, module)

    def test_adopted_deferred_and_missing_are_distinct(self):
        self.assertIsNone(suite_policy({"tests/op_deliver.py": row()}, "tests.op_deliver"))
        self.assertEqual(suite_policy({"tests/op_deliver.py": row("deferred")}, "tests.op_deliver"),
                         "DEFERRED tests.op_deliver: docs/decision.md")
        with self.assertRaises(KeyError):
            suite_policy({}, "tests.new_case")


class WireTests(unittest.TestCase):
    def setUp(self):
        self.connection = NextSocket()
        self.addCleanup(self.connection.close)
        self.sent = []
        self.connection.send_record = self.sent.append

    def test_unnegotiated_operation_is_refused(self):
        with self.assertRaisesRegex(AssertionError, "negotiation"):
            self.connection.send_message(types.OpDeliver(types.DescExport(0), [], False, False))
        self.assertFalse(self.sent)

    def test_constructor_adapter_uses_native_delivery_forms(self):
        self.connection.negotiated = True
        self.connection.send_message(types.OpDeliver(types.DescExport(0), [], False, False))
        self.assertEqual(self.sent.pop(), Record(Symbol("op:deliver-only"), [types.DescExport(0).to_syrup_record(), []]))
        self.connection.send_message(types.OpDeliver(types.DescExport(0), [], 42, types.DescImportObject(7)))
        self.assertEqual(len(self.sent[-1].args), 5)
        self.assertEqual(self.sent[-1].args[-1], 3)

    def test_subscription_overlap_and_initial_settling_fail_before_send(self):
        target = types.DescExport(7).to_syrup_record()
        resolver = types.DescImportObject(9).to_syrup_record()
        with self.assertRaises(AssertionError):
            self.connection.subscribe(target, resolver, 2)
        self.connection.subscribe(target, resolver, 1)
        for mode in (1, 3):
            with self.assertRaises(AssertionError):
                self.connection.subscribe(target, resolver, mode)
        self.connection.subscribe(target, resolver, 2)
        with self.assertRaises(AssertionError):
            self.connection.subscribe(target, resolver, 2)
        self.assertEqual([message.args[-1] for message in self.sent], [1, 2])

    def test_receive_rejects_legacy_arity_and_invalid_next_modes(self):
        self.connection.negotiated = True
        target = types.DescExport(0).to_syrup_record()
        resolver = types.DescImportObject(7).to_syrup_record()
        records = [Record(Symbol("op:deliver"), [target, [], 1, resolver]),
                   Record(Symbol("op:deliver"), [target, [], 1, resolver, 2]),
                   Record(Symbol("op:deliver"), [target, [], 1, resolver, True]),
                   Record(Symbol("op:deliver-only"), [target, [], False])]
        for record in records:
            with self.subTest(record=record), patch("next_wire.Netstring.read", return_value=b""), \
                    patch("next_wire.syrup.syrup_decode", return_value=record):
                with self.assertRaises(AssertionError):
                    self.connection.receive_message()
