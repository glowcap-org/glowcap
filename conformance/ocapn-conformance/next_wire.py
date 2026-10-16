"""Wire fixture for ocapn-conformance-next, using upstream transports and actors.

Translate the pinned suite's old message constructors at the socket boundary.
Assertions remain upstream-owned. Native draft cases inspect wire_kind and
listen_mode so conversion cannot conceal a legacy record from the peer.
The opening and crypto representations intentionally remain the baseline.
"""
import time

from contrib import syrup
from netlayers.base import CapTPSocket, ReadSocketIO
from netlayers.testing_only_tcp import TestingOnlyTCPNetlayer
from utils.captp import CapTPSession
from utils import captp_types as types
from utils.netstrings import Netstring

Symbol = syrup.Symbol
Record = syrup.Record


def key(record):
    return (str(record.label), record.args[0])


class NextSocket(CapTPSocket):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.negotiated = False
        self.subscriptions = {}
        self.settling = {}
        self.hidden = {}
        self.next_hidden = 1 << 62

    def send_record(self, record):
        self.sendall(Netstring(syrup.syrup_encode(record)).to_netstring())

    def hidden_resolver(self, source):
        position = self.next_hidden
        self.next_hidden += 1
        self.hidden[position] = source
        return Record(Symbol("desc:import-object"), [position])

    def subscribe(self, target, resolver, mode):
        source = key(target)
        mask = self.subscriptions.get(source, 0)
        assert mode in (1, 2, 3) and not mask & mode, "duplicate wire listener"
        assert mask or mode != 2, "initial listener must include shortening"
        self.send_record(Record(Symbol("op:listen"), [target, resolver, mode]))
        self.subscriptions[source] = mask | mode
        if mode & 2:
            self.settling[source] = resolver

    def introduce_promises(self, value):
        if isinstance(value, Record):
            if value.label == Symbol("desc:import-promise"):
                target = Record(Symbol("desc:export"), value.args)
                source = key(target)
                if source not in self.subscriptions:
                    self.subscribe(target, self.hidden_resolver(source), 1)
            else:
                self.introduce_promises(value.args)
        elif isinstance(value, (list, tuple)):
            for child in value:
                self.introduce_promises(child)
        elif isinstance(value, dict):
            for child in value.values():
                self.introduce_promises(child)

    def send_message(self, message):
        record = message.to_syrup_record()
        label = str(record.label)
        args = record.args
        if label == "op:start-session":
            assert len(args) == 4, "the deferred crypto transition needs explicit fixture review"
            assert args[0] == "1.0"
            assert args[2].args[2].get("glowcap/captp-version") == "glowcap-next"
        else:
            assert self.negotiated, "operation before verified next negotiation"
        if label == "op:deliver" and len(args) == 4:
            if args[3] is False and args[2] is False:
                record = Record(Symbol("op:deliver-only"), args[:2])
            else:
                mode = 3
                resolver = args[3]
                if resolver is False:
                    mode = 1
                    resolver = self.hidden_resolver(("desc:answer", args[2]))
                record = Record(Symbol("op:deliver"), [*args[:3], resolver, mode])
                if args[2] is not False:
                    self.subscriptions[("desc:answer", args[2])] = mode
        elif label == "op:listen":
            target, resolver, partial = args
            assert type(partial) is bool, "upstream listen constructor changed, review its adapter"
            source = key(target)
            if source not in self.subscriptions:
                self.subscribe(target, self.hidden_resolver(source), 1)
            # Mandatory shortening is already observed by the fixture. The
            # upstream case's independent settling observer stays separate.
            self.subscribe(target, resolver, 2)
            return
        self.send_record(record)

    def receive_message(self, timeout=5):
        deadline = time.monotonic() + min(timeout, 3)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("next fixture receive deadline")
            raw = syrup.syrup_decode(Netstring.read(ReadSocketIO(self, timeout=remaining)))
            assert isinstance(raw, Record)
            label = str(raw.label)
            if label == "op:start-session":
                assert len(raw.args) == 4, "unexpected crypto transition"
                hello = types.OpStartSession.from_syrup_record(raw)
                assert hello.captp_version == "1.0" and hello.valid
                assert hello.location.hints.get("glowcap/captp-version") == "glowcap-next"
                assert hello.location.hints.get("glowcap/codec", "1") == "1"
                self.negotiated = True
                return hello
            assert self.negotiated or label == "op:abort"
            if label in ("op:deliver", "op:deliver-only"):
                if label == "op:deliver":
                    assert len(raw.args) == 5 and type(raw.args[4]) is int and raw.args[4] in (1, 3)
                    assert isinstance(raw.args[3], Record) and str(raw.args[3].label) in ("desc:import-object", "desc:import-promise")
                    old_args = raw.args[:4]
                else:
                    assert len(raw.args) == 2
                    old_args = [*raw.args, False, False]
                self.introduce_promises(raw.args[1])
                target = raw.args[0]
                if str(target.label) == "desc:export" and target.args[0] in self.hidden:
                    assert label == "op:deliver-only"
                    source = self.hidden.pop(target.args[0])
                    verb, shortened = raw.args[1]
                    assert verb == Symbol("fulfill") and isinstance(shortened, Record) and shortened.label == Symbol("desc:import-promise")
                    if source in self.settling:
                        next_target = Record(Symbol("desc:export"), shortened.args)
                        self.subscribe(next_target, self.settling.pop(source), 2)
                    continue
                message = types.OpDeliver.from_syrup_record(Record(Symbol("op:deliver"), old_args))
                message.wire_kind = label
                message.listen_mode = raw.args[4] if label == "op:deliver" else None
                return message
            if label == "op:listen":
                assert len(raw.args) == 3 and type(raw.args[2]) is int and raw.args[2] in (1, 2, 3)
                message = types.OpListen.from_syrup_record(Record(raw.label, [*raw.args[:2], bool(raw.args[2] & 1)]))
                message.listen_mode = raw.args[2]
                return message
            return types.decode_captp_message(raw)


class NextNetlayer(TestingOnlyTCPNetlayer):
    def __init__(self):
        super().__init__()
        self.location.hints["glowcap/captp-version"] = "glowcap-next"

    def upgrade(self, session):
        connection = NextSocket.from_socket(session.connection)
        self._connections.append(connection)
        return CapTPSession(connection, session.location, session.is_outbound)

    def connect(self, target):
        return self.upgrade(super().connect(target))

    def accept(self, timeout=5):
        return self.upgrade(super().accept(timeout))
