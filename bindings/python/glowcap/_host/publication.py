"""Internal Host connector, publication, and session-directory operations."""

from __future__ import annotations

import ctypes
import secrets
from typing import TYPE_CHECKING, Optional

from .. import _constants as _abi
from .._abi_value import _ref_to_c
from .._errors import GlowcapError, _check_host
from .._ffi_host import _host, _SessionLimitOptions
from .._constants_gen import SESSION_LIMIT_OPTIONS_ABI_VERSION
from .._ffi_ocapn import _byte_buf
from .._trampoline import (
    _BehaviorEntry,
    _TRAMPOLINE,
    _register_behavior as _register_global_behavior,
    _unregister_behavior as _unregister_global_behavior,
)
from .._value import Behavior, Ref
from .state import HostMixinBase

_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT

if TYPE_CHECKING:
    from .._session import Session
    from .._transport import Connector


class _PublicationMixin(HostMixinBase):
    def register_connector(self, connector: "Connector") -> None:
        """Retain an explicit byte-fed connector for future handoff dials.

        Registration is keyed by the connector's advertised symbols. Replacing
        a different connector is refused so a later redeem cannot silently use
        a changed transport authority.
        """
        self.install_connectors((connector,))

    def install_connectors(self, connectors) -> None:
        """Publish a connector set atomically.

        Validation walks the complete set and the existing registry before the
        first assignment. A failed install therefore cannot leave a later
        handoff symbol pointing at a connector that was only partly composed.
        """
        from .._transport import Connector

        pending: dict[str, Connector] = {}
        for connector in connectors:
            if not isinstance(connector, Connector):
                raise TypeError(
                    "connectors must contain glowcap transport Connector values"
                )
            for transport in connector.transports:
                prior = self._connectors.get(transport)
                if prior is not None and prior is not connector:
                    raise GlowcapError(
                        _ERR_INVALID_ARGUMENT,
                        f"host already has a different connector for {transport!r}",
                    )
                pending_prior = pending.get(transport)
                if pending_prior is not None and pending_prior is not connector:
                    raise GlowcapError(
                        _ERR_INVALID_ARGUMENT,
                        f"connector set has conflicting authorities for {transport!r}",
                    )
                pending[transport] = connector
        self._connectors.update(pending)

    def _connector_for(self, transport: str) -> "Optional[Connector]":
        return self._connectors.get(transport)

    async def enliven(
        self, sturdyref: str, *, captp_version: "Optional[str]" = None
    ) -> "Ref":
        """Enliven a complete sturdyref without naming a session (ADR-0098):
        the host enlivens it over a live session it already dialed to that
        peer, or dials one itself through this host's own DIAL action and
        finishes when the dial reports. :meth:`Session.enliven` is the
        narrower verb -- it never dials, and refuses a sturdyref for another
        peer."""
        swiss = sturdyref.encode()
        buf, ptr = _byte_buf(swiss)
        out = ctypes.c_uint64()
        if captp_version is None:
            code = _host.glowcap_host_enliven(
                self.raw, ptr, len(swiss), ctypes.byref(out)
            )
        else:
            from .._abi_value import _captp_version_id

            code = _host.glowcap_host_enliven_for_version(
                self.raw,
                _captp_version_id(captp_version),
                ptr,
                len(swiss),
                ctypes.byref(out),
            )
        _check_host(code)
        return await self._await_host_capability(out.value, sturdyref)

    async def fetch_at(self, locator, name: str) -> "Ref":
        """Fetch ``name`` at a typed locator through this Host's profile."""
        from .._locator import _OwnedLocator
        encoded = name.encode()
        _buf, ptr = _byte_buf(encoded)
        out = ctypes.c_uint64()
        with _OwnedLocator.create(locator) as owned:
            _check_host(
                _host.glowcap_host_fetch_at(
                    self.raw,
                    owned.borrow_view(),
                    ptr,
                    len(encoded),
                    ctypes.byref(out),
                )
            )
        return await self._await_host_capability(out.value, name)

    async def _await_host_capability(self, vow: int, subject: str) -> Ref:
        from .._promise import _classify_live_ref

        self.vow_minted(vow)
        settled = self.await_vow(vow)
        try:
            await self.kick_actions()
            return _classify_live_ref(await settled, subject)
        finally:
            self._gc.park_vow(vow)

    def set_advertised_locator(self, locator) -> None:
        """Retain a validated clone of this Host's complete location."""
        from .._locator import _OwnedLocator

        with _OwnedLocator.create(locator) as owned:
            _check_host(
                _host.glowcap_host_set_advertised_locator(self.raw, owned.borrow_view())
            )

    def remove_advertised_locator(self, transport: str) -> None:
        """Remove this Host's retained locator for ``transport``."""
        data = transport.encode()
        buf, ptr = _byte_buf(data)
        _check_host(
            _host.glowcap_host_remove_advertised_locator(self.raw, ptr, len(data))
        )

    def set_session_limits(
        self,
        *,
        max_frame_bytes: int = 0,
        queue_cap: int = 0,
        outbound_high_water_bytes: int = 0,
        max_retained_sent_answer_bytes: int = 0,
    ) -> None:
        """Apply selective limits to peers minted after this call.

        Zero leaves that field unchanged. The durable sent-answer budget is
        separate from transient outbound flow pressure.
        """
        values = (
            max_frame_bytes,
            queue_cap,
            outbound_high_water_bytes,
            max_retained_sent_answer_bytes,
        )
        if any(
            isinstance(value, bool) or not isinstance(value, int) or value < 0
            for value in values
        ):
            raise ValueError("session limits must be non-negative integers")
        options = _SessionLimitOptions(
            SESSION_LIMIT_OPTIONS_ABI_VERSION,
            ctypes.sizeof(_SessionLimitOptions),
            *values,
        )
        _check_host(
            _host.glowcap_host_set_session_limits(self.raw, ctypes.byref(options))
        )

    def designator(self) -> str:
        """The canonical key designator (64 lowercase hex digits) for this
        node's identity seed — what a keyed-tcp locator names as its
        designator (ADR-0075)."""
        out = (ctypes.c_ubyte * 64)()
        buf, ptr = _byte_buf(self._seed)
        _check_host(_host.glowcap_host_designator_from_seed(ptr, 32, out, 64))
        return bytes(out).decode("ascii")

    def publish_giftable(self, name: str, behavior: Behavior) -> None:
        """Host ``behavior`` once and bind ``name`` as a Host-wide alias.

        Fetch lazily projects the actor onto a session. A deposited gift keeps
        that exact actor when a recipient later withdraws over its own exporter
        session (ADR-0009)."""
        # A giftable is bound to no single session: its forwards always go
        # through the host, and a turn it runs belongs to whichever session
        # the deliver arrived on.
        ctx = self._register_behavior(_BehaviorEntry(run=behavior, resolve_local=None))
        data = name.encode()
        buf, ptr = _byte_buf(data)
        try:
            _check_host(
                _host.glowcap_host_publish(
                    self.raw,
                    ptr,
                    len(data),
                    _TRAMPOLINE,
                    ctypes.c_void_p(ctx),
                    None,
                )
            )
        except BaseException:
            # free = NULL: the C tier never owns the row, so a refused publish
            # must drop it here or the registry pins the behavior forever.
            self._unregister_behavior(ctx)
            raise
        prior = self._giftables.get(name)
        if prior is not None:
            # Replacement moves discovery only. Existing capabilities and
            # deposited gifts can still call the old actor.
            self._displaced_giftables.append(prior)
        self._giftables[name] = ctx

    def unpublish_giftable(self, name: str) -> bool:
        """Remove the Host-wide alias ``name`` (alias-only).

        A later fetch misses on every session, while issued refs and deposited
        gifts keep the exact actor, whose behavior stays hosted for the Host's
        life. Returns ``False`` when no such alias exists."""
        data = name.encode()
        buf, ptr = _byte_buf(data)
        rc = _host.glowcap_host_unpublish(self.raw, ptr, len(data))
        if rc == _abi.ERR_NOT_FOUND:
            return False
        _check_host(rc)
        # The alias is gone but the actor is not: its trampoline row moves to
        # the displaced list, exactly as a replacement displaces one.
        prior = self._giftables.pop(name, None)
        if prior is not None:
            self._displaced_giftables.append(prior)
        self.schedule_kick()
        return True

    def publish_durable(
        self, behavior: Behavior, entropy: Optional[bytes] = None
    ) -> str:
        """Publish ``behavior`` under a freshly minted durable swiss name and
        return that name — the swiss to place in a sturdyref beside this
        host's own locator (ADR-0098).

        The name is unpredictable, never reassigned, structurally disjoint
        from every mutable alias, and removable only through
        :meth:`remove_durable`. When supplied, ``entropy`` must be exactly
        ``HOST_DURABLE_ENTROPY_LEN`` bytes and restores the same name on a
        Host reconstructed from the same seed; otherwise this method draws
        it from the OS RNG."""
        raw = self.raw
        width = _abi.HOST_DURABLE_ENTROPY_LEN
        if entropy is None:
            entropy_bytes = secrets.token_bytes(width)
        else:
            entropy_bytes = bytes(entropy)
            if len(entropy_bytes) != width:
                raise GlowcapError(
                    _ERR_INVALID_ARGUMENT,
                    f"durable entropy must be exactly {width} bytes",
                )
        ctx = self._register_behavior(_BehaviorEntry(run=behavior, resolve_local=None))
        ebuf, eptr = _byte_buf(entropy_bytes)
        swiss_len = _abi.HOST_DURABLE_SWISS_LEN
        out = (ctypes.c_ubyte * swiss_len)()
        try:
            written = _host.glowcap_host_publish_durable(
                raw,
                eptr,
                len(entropy_bytes),
                _TRAMPOLINE,
                ctypes.c_void_p(ctx),
                None,
                out,
                swiss_len,
            )
            if written <= 0:
                _check_host(written)
        except BaseException:
            # free = NULL: the C tier never owns the row, so a refused publish
            # must drop it here or the registry pins the behavior forever.
            self._unregister_behavior(ctx)
            raise
        name = bytes(out[:written]).decode("ascii")
        self._giftables[name] = ctx
        self.schedule_kick()
        return name

    def _register_behavior(self, entry: _BehaviorEntry) -> int:
        """Retain one callback entry for this Host's native lifetime."""
        ctx = _register_global_behavior(entry)
        self._behavior_entries[ctx] = entry
        return ctx

    def _unregister_behavior(self, ctx: int) -> None:
        """Undo a refused callback mint before it joins Host authority."""
        self._behavior_entries.pop(ctx, None)
        _unregister_global_behavior(ctx)

    def remove_durable(self, swiss: str) -> bool:
        """Remove a minted durable publication (ADR-0098).

        The old sturdyref misses from now on, while issued refs and deposited
        gifts keep the exact actor. Returns ``False`` when no such durable
        name exists."""
        data = swiss.encode()
        buf, ptr = _byte_buf(data)
        rc = _host.glowcap_host_remove_durable(self.raw, ptr, len(data))
        if rc == _abi.ERR_NOT_FOUND:
            return False
        _check_host(rc)
        prior = self._giftables.pop(swiss, None)
        if prior is not None:
            self._displaced_giftables.append(prior)
        self.schedule_kick()
        return True

    def register_session(self, ptr: int, session: "Session") -> None:
        """Track a live session by its session address. Binding-internal: the
        :class:`Session` constructor calls it."""
        self._sessions[ptr] = session

    def unregister_session(self, ptr: int) -> None:
        """Stop tracking a released session. Binding-internal."""
        self._sessions.pop(ptr, None)

    def exporter_for(self, ref: Ref) -> "Optional[Session]":
        """The live :class:`Session` homing remote ``ref``, or ``None`` for a
        local, stale, foreign-Host, or closed-session capability.

        The answer is deterministic (ADR-0088): the reply's own token carries
        which session it lives in, so :meth:`Session.send_redeeming` resolves
        the exact exporter session it should host its back-channel on. There is
        no capture window and no dependence on which dial finished first, so it
        is right with several redeems in flight, and it finds an exporter a
        prior redeem already dialed -- a cache hit that opens no new session.
        :meth:`Session.send_redeeming` suppresses its own sending session and
        surfaces only a different exporter. Binding-internal."""
        c_ref = _ref_to_c(ref._live())
        if self._driver_loop is not None:
            out_value = self._driver_loop.claim_reference_exporter(c_ref)
        else:
            out = ctypes.c_void_p()
            _check_host(
                _host.glowcap_host_reference_exporter(
                    self.raw,
                    ctypes.byref(c_ref),
                    ctypes.byref(out),
                )
            )
            out_value = out.value
        # The handle is host-owned and lives with the exporter session, so the
        # registry lookup is the whole answer: a pointer with no live row is a
        # session this binding no longer holds, which reads as no route.
        found = self._sessions.get(out_value) if out_value else None
        if found is None and out_value and self._driver_loop is not None:
            # A loop-owned Host redeems inside its own steps (ADR-0112), so
            # the exporter session it dialed exists with no wrapper yet. Wrap
            # it lazily — the constructor registers it, so a repeat lookup
            # returns this same object — and the loop stays its release
            # authority through the transport's back-reference.
            from .._loop import DriverLoop

            assert isinstance(self._driver_loop, DriverLoop)
            found = self._driver_loop.adopt_session(out_value)
        return found
