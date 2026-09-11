import unittest

from _protocol_gen import ARRIVE, DEPART, MEMBERSHIP_ENDED, PUBLICATION_FIELDS, ROOM_SENDER, STAY
from room_client import MAX_UNREAD_LINES, Room, _read_presence, _room, _watch_room_event


class TerminalClientContractTests(unittest.TestCase):
    def test_unread_lines_stop_at_the_named_ceiling(self) -> None:
        room = Room(object())
        for at in range(MAX_UNREAD_LINES):
            room._emit("peer", str(at))
        with self.assertRaisesRegex(RuntimeError, str(MAX_UNREAD_LINES)):
            room._emit("peer", "one more")
        self.assertEqual(room._lines.qsize(), MAX_UNREAD_LINES)

    def test_membership_ended_is_the_last_line_and_ends_the_stream(self) -> None:
        room = Room(object())
        room._inbox("notify", [ROOM_SENDER, "kicked by the steward", MEMBERSHIP_ENDED])
        self.assertTrue(room._ended)
        last = room._lines.get_nowait()
        self.assertEqual((last.sender, last.text, last.system), (ROOM_SENDER, "kicked by the steward", True))
        self.assertRegex(str(room._failure), "kicked by the steward")
        with self.assertRaisesRegex(ValueError, "membership-ended notify takes one reason"):
            Room(object())._inbox("notify", [ROOM_SENDER, "", MEMBERSHIP_ENDED])
        with self.assertRaisesRegex(ValueError, "membership-ended notify takes one reason"):
            Room(object())._inbox("notify", ["ada", "bye", MEMBERSHIP_ENDED])
        with self.assertRaisesRegex(ValueError, "membership-ended notify takes one reason"):
            Room(object())._inbox("notify", [ROOM_SENDER, "bye", MEMBERSHIP_ENDED, "extra"])

    def test_malformed_watch_callbacks_are_refused(self) -> None:
        with self.assertRaisesRegex(ValueError, "malformed room watch"):
            _watch_room_event(["opened", "only-a-name"])
        self.assertEqual(
            _watch_room_event(
                ["registered", "ada", 1, "00000000-0000-4000-8000-000000000001"]
            ),
            ("registered", None),
        )
        with self.assertRaisesRegex(ValueError, "malformed registered watch"):
            _watch_room_event(["registered", "ada", 1, "not-a-registration-id"])
        with self.assertRaisesRegex(ValueError, "unknown watch event"):
            _watch_room_event(["renamed", "lobby"])

    def test_a_wire_null_is_an_unknown_count_and_an_absent_offer(self) -> None:
        foreign = _room(["lobby", None, "id-1", "foreign", "ocapn://x", "session", "participant"])
        self.assertIsNotNone(foreign)
        self.assertIsNone(foreign.count)
        self.assertEqual(foreign.offers, "participant")
        closed = _room(["lobby", 2, "id-2", "local", "", "local", None])
        self.assertEqual((closed.count, closed.offers), (2, None))
        self.assertIsNone(_room(["lobby", True, "id-3", "local", "", "local", None]))
        self.assertIsNone(_room(["lobby", 2, "id-4", "local", "", "local", "steward"]))
        self.assertEqual(len(PUBLICATION_FIELDS), 7)

    def test_presence_reads_every_generated_tail_with_its_effect(self) -> None:
        roster = _read_presence(ROOM_SENDER, "welcome", [ROOM_SENDER, "welcome", "roster", "ada", "bo"])
        self.assertEqual((roster.kind, roster.names, roster.effect), ("roster", ["ada", "bo"], ARRIVE))
        gone = _read_presence(ROOM_SENDER, "bo left", [ROOM_SENDER, "bo left", "leave", "bo"])
        self.assertEqual((gone.names, gone.effect), (["bo"], DEPART))
        typing = _read_presence(ROOM_SENDER, "", [ROOM_SENDER, "", "typing", "ada", True])
        self.assertEqual((typing.names, typing.effect), (["ada"], STAY))
        self.assertIsNone(_read_presence("ada", "hi", ["ada", "hi"]))
        self.assertIsNone(_read_presence("ada", "hi", ["ada", "hi", "join", "bo"]))
        self.assertIsNone(_read_presence(ROOM_SENDER, "", [ROOM_SENDER, "", "typing", "ada"]))


if __name__ == "__main__":
    unittest.main()
