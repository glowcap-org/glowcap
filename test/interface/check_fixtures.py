"""Fixture integrity for `zig build interface-fixtures-check` (repository cwd).

Uses the pinned upstream Syrup implementation, not a compiler under test.
No arguments, writes, network, or extra dependencies. Exits nonzero on failure.
This checks authored fixture facts; it is not the future description validator.
"""
import importlib.util
import io
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "syrup", ROOT / "conformance/ocapn-conformance/upstream/contrib/syrup.py"
)
syrup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(syrup)


class FixtureStream(io.BytesIO):
    # Upstream's whitespace loop treats empty bytes as whitespace at EOF.
    # Stop truncated repository fixtures instead of spinning until the deadline.
    def read(self, size=-1):
        data = super().read(size)
        if size > 0 and len(data) != size:
            raise EOFError("truncated Syrup fixture")
        return data


def read_canonical(data):
    stream = FixtureStream(data)
    value = syrup.syrup_read(stream)
    if stream.read() or syrup.syrup_encode(value) != data:
        raise ValueError("fixture is not one canonical Syrup value")
    return value


def record(value, label):
    if not isinstance(value, syrup.Record) or value.label.name != label:
        raise ValueError(f"expected {label} record")
    return value.args


class Fixtures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contract_bytes = (ROOT / "test/interface/contracts.syrup").read_bytes()
        version, cls.profiles, cls.defs = record(
            read_canonical(cls.contract_bytes), "glowcap:interface"
        )
        if version != 1:
            raise ValueError("unexpected description version")
        cls.messages = read_canonical((ROOT / "test/interface/messages.syrup").read_bytes())

    def methods(self, name):
        return record(self.defs[name], "interface")[0]

    def test_tasks_surface_and_public_creation_results(self):
        for name, names in {
            "tasks.Board": {"lists", "list", "add-list"},
            "tasks.TaskList": {"name", "count", "task", "add", "move"},
            "tasks.Task": {"text"},
        }.items():
            self.assertEqual(set(self.methods(name)), names)
        for owner, method, result in [
            ("tasks.Board", "add-list", "tasks.TaskList"),
            ("tasks.TaskList", "add", "tasks.Task"),
        ]:
            _, reply, convention = record(self.methods(owner)[method], "method")
            self.assertEqual(record(reply, "ref"), [result])
            self.assertEqual(convention.name, "loam.receipt")
        expected = {"tasks.Name": (1, 64), "tasks.Text": (1, 4096)}
        for name, (minimum, maximum) in expected.items():
            kind, bounds = record(record(self.defs[name], "type")[0], "bounded")
            self.assertEqual(kind.name, "string")
            self.assertEqual(bounds, {"min_bytes": minimum, "max_bytes": maximum})

    def test_integer_ranges_and_hostile_names(self):
        for name, lower, upper in [
            ("tasks.ListCount", 0, 16), ("tasks.TaskCount", 0, 256),
            ("tasks.Index", 0, 9223372036854775807),
            ("loam.Sequence", 1, 9223372036854775807),
        ]:
            kind, bounds = record(record(self.defs[name], "type")[0], "bounded")
            self.assertEqual(kind.name, "integer")
            self.assertEqual(bounds, {"min": lower, "max": upper})
        names = self.methods("fixture.Hostile")
        self.assertTrue({"then", "a-b", "a_b", "", "../escape"} <= names.keys())
        self.assertIn(False, self.methods("fixture.Direct"))
        self.assertNotIn(False, names)

    def test_reference_closure(self):
        found = set()
        def visit(value):
            if isinstance(value, syrup.Record):
                if value.label.name == "ref":
                    found.add(value.args[0])
                for item in value.args:
                    visit(item)
            elif isinstance(value, dict):
                for item in value.values():
                    visit(item)
            elif isinstance(value, list):
                for item in value:
                    visit(item)
        visit(self.defs)
        self.assertTrue(found)
        self.assertFalse(found - self.defs.keys())
        self.assertEqual(self.profiles, {"glowcap.values": 1, "loam.receipt": 1})

    def test_receipt_envelope_is_not_an_ordinary_method_call(self):
        # Authored separately from the descriptions: exact symbol/string distinction.
        self.assertEqual(syrup.syrup_encode(self.messages["create"]),
                         b'[6\'mutate1+3"add11"write tests]')
        self.assertEqual(syrup.syrup_encode(self.messages["sequence"]),
                         b"[17'mutation-sequence]")
        self.assertEqual(syrup.syrup_encode(self.messages["direct"]), b'[5"hello]')

    def test_direct_and_empty_named_invocation_are_distinct(self):
        self.assertEqual(syrup.syrup_encode(self.messages["direct-empty"]), b"[]")
        self.assertEqual(syrup.syrup_encode(self.messages["named-empty"]), b"[0']")

    def test_observation_has_five_positional_fields(self):
        tag, fields = record(record(self.defs["loam.Observation"], "type")[0], "record")
        self.assertEqual(tag, "access:observation")
        self.assertEqual(len(fields), 5)
        self.assertEqual(record(fields[0], "ref"), ["loam.Cursor"])
        self.assertEqual([f.name for f in fields[1:4]], ["value", "bool", "bool"])
        for name in ("poll", "receive"):
            params, _, _ = record(self.methods("loam.Receiver")[name], "method")
            self.assertEqual(len(params), 1)
            self.assertTrue(record(params[0], "parameter")[2])

    def test_trailing_and_noncanonical_input_fail(self):
        for data in (self.contract_bytes + b"f", b"01+", self.contract_bytes[:-1]):
            with self.assertRaises((ValueError, syrup.SyrupDecodeError, EOFError, IndexError)):
                read_canonical(data)


if __name__ == "__main__":
    unittest.main()
