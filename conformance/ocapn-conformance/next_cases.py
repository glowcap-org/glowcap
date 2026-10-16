"""Draft-native next cases, run by ocapn-conformance-next alongside upstream cases.

Authority: pinned CapTP op:deliver, op:deliver-only, op:listen, and PR293
projection removals. The crypto representations stay deliberately deferred.
"""
from contrib.syrup import Record, Symbol
from utils.test_suite import CapTPTestCase
from utils import captp_types as types


class DraftOperations(CapTPTestCase):
    def setUp(self):
        super().setUp()
        self.remote.setup_session("1.0")

    def echo(self):
        return self.remote.fetch_object(b"IO58l1laTyhcrgDKbEzFOO32MDd6zE5w")

    def send(self, label, args):
        self.remote.connection.send_record(Record(Symbol(label), args))

    def test_deliver_result_without_pipeline_slot(self):
        resolver = self.remote.next_import_object
        self.send("op:deliver", [self.echo().to_syrup_record(), ["result"], False,
                                 resolver.to_syrup_record(), 3])
        reply = self.remote.expect_promise_resolution(resolver.to_desc_export(), timeout=3)
        self.assertEqual(reply.wire_kind, "op:deliver-only")
        self.assertEqual(reply.args, [Symbol("fulfill"), ["result"]])

    def test_shortening_only_deliver_can_add_settling_listener(self):
        resolver = self.remote.next_import_object
        answer = self.remote.next_answer
        self.send("op:deliver", [self.echo().to_syrup_record(), ["settled"], answer.position,
                                 resolver.to_syrup_record(), 1])
        # A late settling listener observes the stored value. The mode-1
        # resolver must not receive a settled value, including before this.
        settled = self.remote.next_import_object
        self.send("op:listen", [answer.to_syrup_record(), settled.to_syrup_record(), 2])
        for _ in range(8):
            reply = self.remote.receive_message(timeout=3)
            if isinstance(reply, types.OpDeliver):
                self.assertEqual(reply.to, settled.to_desc_export())
                self.assertEqual(reply.wire_kind, "op:deliver-only")
                self.assertEqual(reply.args, [Symbol("fulfill"), ["settled"]])
                break
        else:
            self.fail("settling result missing")

    def test_deliver_only_executes_without_requesting_reply(self):
        greeter = self.remote.fetch_object(b"VMDDd1voKWarCe2GvgLbxbVFysNzRPzx")
        target = self.remote.next_import_object
        self.send("op:deliver-only", [greeter.to_syrup_record(), [target.to_syrup_record()]])
        reply = self.remote.expect_message_to(target.to_desc_export(), timeout=3)
        # The greeter's own send expects a result, independently of our
        # deliver-only request. It must use the five-operand draft envelope.
        self.assertEqual(reply.wire_kind, "op:deliver")
        self.assertEqual(reply.listen_mode, 3)
        self.assertIsNot(reply.resolve_me_desc, False)
        self.assertEqual(reply.args, ["Hello"])

    def test_duplicate_promise_arguments_share_one_shortening_subscription(self):
        echo = self.echo()
        promise = types.DescImportPromise(1000).to_syrup_record()
        resolver = self.remote.next_import_object
        self.send("op:deliver", [echo.to_syrup_record(), [promise, promise], False, resolver.to_syrup_record(), 3])
        replies = 0
        listens = []
        for _ in range(12):
            message = self.remote.receive_message(timeout=3)
            if isinstance(message, types.OpListen):
                listens.append(message)
            if isinstance(message, types.OpDeliver):
                self.assertEqual(message.wire_kind, "op:deliver-only")
                replies += 1
                break
        self.assertEqual(replies, 1)
        self.assertTrue(listens)
        modes = 0
        for listen in listens:
            self.assertEqual(listen.to, types.DescExport(1000))
            self.assertEqual(modes & listen.listen_mode, 0)
            if modes == 0:
                self.assertIn(listen.listen_mode, (1, 3))
            modes |= listen.listen_mode
        self.assertEqual(sum(bool(listen.listen_mode & 1) for listen in listens), 1)

    def test_pipelined_resolver_only_calls_can_share_callback_capability(self):
        factory = self.remote.fetch_object(b"JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ", pipeline=True)
        resolver = self.remote.next_import_object
        for _ in range(2):
            self.send("op:deliver", [factory.to_syrup_record(), [], False, resolver.to_syrup_record(), 3])
        for _ in range(2):
            reply = self.remote.expect_promise_resolution(resolver.to_desc_export(), timeout=3)
            self.assertEqual(reply.wire_kind, "op:deliver-only")
            self.assertEqual(reply.args[0], Symbol("fulfill"))
            self.assertIsInstance(reply.args[1], types.DescImportObject)

    def test_deliver_only_promise_arguments_require_shortening(self):
        greeter = self.remote.fetch_object(b"VMDDd1voKWarCe2GvgLbxbVFysNzRPzx")
        self.send("op:deliver-only", [greeter.to_syrup_record(), [types.DescImportPromise(1001).to_syrup_record()]])
        listen = self.remote.expect_message_type(types.OpListen, timeout=3)
        self.assertEqual(listen.to, types.DescExport(1001))
        self.assertEqual(listen.listen_mode, 1)

    def test_deliver_mode_two_is_refused(self):
        resolver = self.remote.next_import_object
        self.send("op:deliver", [self.echo().to_syrup_record(), [], False,
                                 resolver.to_syrup_record(), 2])
        reply = self.remote.expect_message_type(types.OpAbort, timeout=3)
        self.assertIsInstance(reply, types.OpAbort)

    def test_removed_operations_are_refused(self):
        for operation, operand in [("op:get", "field"), ("op:index", 0), ("op:untag", "tag")]:
            with self.subTest(operation=operation):
                other = self.netlayer.connect(self.ocapn_uri)
                try:
                    other.setup_session("1.0")
                    other.connection.send_record(Record(Symbol(operation), [types.DescExport(0).to_syrup_record(), operand, 11]))
                    self.assertIsInstance(other.expect_message_type(types.OpAbort, timeout=3), types.OpAbort)
                finally:
                    other.close()
