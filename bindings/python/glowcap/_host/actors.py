"""Internal Host actor verbs: spawn, send, and tell with no session."""

from __future__ import annotations

import asyncio
import ctypes

from .._abi_value import _ref_to_c
from .._errors import _check_host
from .._ffi_host import _host, _selector_buf
from .._ffi_ocapn import _Reference
from .._promise import RemotePromise, _FarArguments
from .._trampoline import _HOSTED_FREE, _TRAMPOLINE, _BehaviorEntry, _current_host_turn, _turn_spawn
from .._value import Argument, Behavior, Ref
from .state import HostMixinBase


def _host_target(target: Ref) -> Ref:
    # A RemotePromise belongs to the Session that minted it, and the Host
    # verbs address only references, so refuse it before any marshalling.
    if not isinstance(target, Ref):
        raise TypeError(f"a Host verb targets a Ref this Host holds, not {type(target).__name__}")
    return target._live()


class _ActorMixin(HostMixinBase):
    def spawn(self, behavior: Behavior) -> Ref:
        """Host ``behavior`` with no session, alias, or wire export.

        The returned reference is owned. When it and every exported copy are
        gone, the actor is collected and its behavior entry is released.
        Sending it over any session exports it there. Inside a behavior
        callback the spawn joins that turn. A refused spawn raises
        :class:`GlowcapError` and hosts nothing.
        """
        turn = _current_host_turn(self)
        raw = self.raw if turn is None else None
        ctx = self._register_behavior(_BehaviorEntry(run=behavior, resolve_local=None), ffi_owned=True)
        try:
            if turn is not None:
                ref_id = _turn_spawn(turn, ctx, _HOSTED_FREE)
            else:
                out = _Reference()
                _check_host(
                    _host.glowcap_host_spawn(raw, _TRAMPOLINE, ctypes.c_void_p(ctx), _HOSTED_FREE, ctypes.byref(out))
                )
                ref_id = out.id
        except BaseException:
            # The library frees an admitted registration on failure and leaves
            # a null or reentry refusal with us. Unregistering is idempotent
            # with that free, so both outcomes end with no entry.
            self._unregister_behavior(ctx)
            raise
        return self._gc.adopt_ref(ref_id)

    def send(self, target: Ref, verb: str | None, args: list | None = None) -> asyncio.Future[Argument]:
        """Eventual-send ``verb(args)`` to ``target`` at its actual home.

        ``target`` is a :class:`Ref` this Host holds, local or far. A
        :class:`RemotePromise` is refused, so pipeline through
        :meth:`Session.send` instead. The send is admitted before this
        returns, and the returned future settles with the answer. The Host
        queue owns admitted work, so abandoning the future does not cancel
        it, and the answer's vow is released when it settles. Inside a
        behavior callback the send commits with that turn.

        A refused send queues nothing and returns a future that raises the
        refusal, like :meth:`Session.send`, so ``asyncio.gather`` sees every
        sibling. Called with no running event loop, it raises
        :class:`RuntimeError` before anything is queued.
        """
        # The answer's future needs the running loop, so check it before the
        # send commits rather than after.
        asyncio.get_running_loop()
        try:
            turn = _current_host_turn(self)
            raw = self.raw
            ref = _ref_to_c(_host_target(target))
            _vbuf, vptr, verb_len = _selector_buf(verb)
            out = ctypes.c_uint64()
            with _FarArguments(self, list(args) if args is not None else []) as (arr, count):
                if turn is None:
                    code = _host.glowcap_host_send(
                        raw, ctypes.byref(ref), vptr, verb_len, arr, count, ctypes.byref(out)
                    )
                else:
                    code = _host.glowcap_host_turn_send(
                        turn, ctypes.byref(ref), vptr, verb_len, arr, count, ctypes.byref(out)
                    )
                _check_host(code)
        except Exception as err:
            return RemotePromise.failed(err)
        # Committed. The loop and owner thread were checked above, so recording
        # the vow and scheduling the drain cannot refuse.
        vow = out.value
        self.vow_minted(vow, track_gc=True)
        settled = self.await_vow(vow)
        settled.add_done_callback(lambda _settled: self._gc.park_vow(vow))
        self.schedule_kick()
        return settled

    def tell(self, target: Ref, verb: str | None, args: list | None = None) -> None:
        """Queue a notification to ``target`` at its actual home with no reply.

        ``target`` is a :class:`Ref` this Host holds, and a
        :class:`RemotePromise` is refused. This returns once the notification
        is queued, where :meth:`Session.tell` is awaited. A refusal raises
        :class:`GlowcapError` and queues nothing. Inside a behavior callback
        the notification commits with that turn.
        """
        turn = _current_host_turn(self)
        raw = self.raw
        ref = _ref_to_c(_host_target(target))
        _vbuf, vptr, verb_len = _selector_buf(verb)
        with _FarArguments(self, list(args) if args is not None else []) as (arr, count):
            if turn is None:
                code = _host.glowcap_host_tell(raw, ctypes.byref(ref), vptr, verb_len, arr, count)
            else:
                code = _host.glowcap_host_turn_tell(turn, ctypes.byref(ref), vptr, verb_len, arr, count)
            _check_host(code)
        self.schedule_kick()
