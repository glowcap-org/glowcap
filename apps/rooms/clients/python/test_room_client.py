import unittest

from room_client import MAX_UNREAD_LINES, Room, _watch_room_event


class TerminalClientContractTests(unittest.TestCase):
    def test_unread_lines_stop_at_the_named_ceiling(self) -> None:
        room = Room(object(), object())
        for at in range(MAX_UNREAD_LINES):
            room._emit("peer", str(at))
        with self.assertRaisesRegex(RuntimeError, str(MAX_UNREAD_LINES)):
            room._emit("peer", "one more")
        self.assertEqual(room._lines.qsize(), MAX_UNREAD_LINES)

    def test_malformed_watch_callbacks_are_refused(self) -> None:
        with self.assertRaisesRegex(ValueError, "malformed room watch"):
            _watch_room_event(["opened", "only-a-name"])
        self.assertEqual(
            _watch_room_event(
                ["registered", "ada", 1, "00000000-0000-4000-8000-000000000001"]
            ),
            ("registered", None),
        )


if __name__ == "__main__":
    unittest.main()
