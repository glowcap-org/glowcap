"""Session capability, peer-identity, and distributed-GC verbs."""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
from typing import TYPE_CHECKING, NamedTuple, Optional, cast

from .. import _constants as _abi
from .._constants import DurableProvenance, _provenance_from_abi
from .._errors import GlowcapError, _check_host
from .._ffi_host import _PartnerIdentity, _host
from .._ffi_ocapn import _byte_buf, _Reference
from .._gc import release_ref
from .._locator import _OwnedLocator, Locator
from .._promise import RemotePromise, _fetch_like, _listen_far
from .._trampoline import (
    Caretaker,
    _attenuate_proxy,
    _caretaker_proxy,
    _dispatch_send,
    _dispatch_tell,
    _publish_hosted,
    _spawn_hosted,
)
from .._value import Argument, Behavior, Ref, _ref_from_id

if TYPE_CHECKING:
    from .._host import Host
    from . import Session


class SendRedeemingResult(NamedTuple):
    """What :meth:`Session.send_redeeming` hands back: the ``reply`` the send
    settled to, and ``via``, the direct exporter :class:`Session` that reply
    routes to (``None`` when it routes to no live redeemed exporter).

    A :class:`~typing.NamedTuple`, so it unpacks like the pair it is while
    naming both halves for callers that only need one.
    """

    reply: Argument
    via: Optional["Session"]


@dataclass(frozen=True)
class PartnerIdentity:
    """The identity :meth:`Session.partner_identity` proves about the peer.

    ``session_key`` is the partner's session public key. ``designator`` is the
    location designator it signed. ``locator_record`` is that complete signed
    record. ``provenance`` says what, if anything, authenticated the durable
    identity at the channel layer.
    """

    session_key: bytes
    designator: str
    locator_record: bytes
    provenance: DurableProvenance

    def durable_identity_authenticated(self) -> bool:
        """Whether the realized channel authenticated the durable identity."""
        return self.provenance is not DurableProvenance.UNAUTHENTICATED


# These are public types exported from ``glowcap._session``. Keep their
# introspection and pickle authority stable even though verbs owns the bodies.
SendRedeemingResult.__module__ = "glowcap._session"
PartnerIdentity.__module__ = "glowcap._session"


class _VerbsMixin:
    """Application operations over root-owned Session state."""

    if TYPE_CHECKING:
        _host: Host
        _ptr: ctypes.c_void_p | None
        _hosted: dict[int, int]
        _gc_enabled: bool

        def guard_open(self) -> None: ...

        def raise_wire_failure(self) -> None: ...

    def spawn(self, behavior: Behavior) -> Ref:
        """Spawn a local actor and return its Host-scoped capability.

        The returned identity is opaque. Wire export positions remain inside
        glowcap. It is valid inside a served turn, including a factory minting
        the object it replies with.
        """
        return _spawn_hosted(self, behavior)

    def publish(self, name: str, behavior: Behavior) -> Ref:
        """Publish an actor under the partner-visible swiss number ``name``.

        The name is discoverable for a service and secret where knowing it is
        itself the authorization.
        """
        return _publish_hosted(self, name, behavior)

    def caretaker(self, target: Ref) -> Caretaker:
        """Return a revocable caretaker proxy for a local or far target.

        Calls forward until :meth:`Caretaker.revoke`. Later calls break with
        ``Revoked``. This can safely wrap authority imported from a partner.
        """
        return _caretaker_proxy(self.spawn, target)

    def attenuate(self, target: Ref, verbs: "list[str]") -> Ref:
        """Return a proxy that forwards only the named verbs.

        Every other call breaks with ``Attenuated``. The target may be local
        or far. The returned proxy is an ordinary capability to hand onward.
        """
        return _attenuate_proxy(self.spawn, target, verbs)

    async def fetch(self, name: str) -> Ref:
        """Fetch the capability published by the partner under ``name``.

        The method starts inbound service itself. A partner break is surfaced
        as :class:`VowBroken`. A fulfillment that is not a live capability is
        :class:`FetchFailed`.
        """
        return await _fetch_like(
            self,
            name.encode(),
            name,
            _host.glowcap_host_session_fetch,
            track=True,
        )

    async def enliven(self, sturdyref: str) -> Ref:
        """Enliven a sturdyref against this already-open session.

        The complete locator is verified before the Host's dedup cache is
        consulted. This Session-level verb never dials.
        """
        return await _fetch_like(
            self,
            sturdyref.encode(),
            sturdyref,
            _host.glowcap_host_session_enliven,
            track=True,
        )

    def send(
        self, target: "Ref | RemotePromise", verb: str | None, args: "Optional[list]" = None
    ) -> RemotePromise:
        """Eventual-send ``verb(args)`` and return a pipelineable promise.

        ``target`` may be a :class:`Ref` or an earlier
        :class:`RemotePromise`. The latter addresses the unresolved answer
        directly, so dependent sends travel as one pipelined batch. Capability
        arguments route to their actual exporter transparently.
        """
        # Synchronous issue failures belong on the returned handle. Raising
        # here would escape a caller's gather before it can observe the vow.
        try:
            self.guard_open()
            self._host.gc.drain_gc()
            return _dispatch_send(self, target, verb, args if args is not None else ())
        except Exception as err:  # noqa: BLE001 - reported through the handle
            return RemotePromise.failed(err)

    def listen(self, target: Ref) -> RemotePromise:
        """Listen to a far promise or permitted far object via ``op:listen``.

        The notification may be any value. In 1.0 a far promise or live far
        object is accepted. glowcap-next requires a promise.
        """
        try:
            self.guard_open()
            self._host.gc.drain_gc()
            return _listen_far(self, target)
        except Exception as err:  # noqa: BLE001 - reported through the handle
            return RemotePromise.failed(err)

    async def send_redeeming(
        self,
        target: "Ref | RemotePromise",
        verb: str | None,
        args: "Optional[list]" = None,
    ) -> SendRedeemingResult:
        """Send and surface the direct exporter Session opened by redemption.

        A handoff reply may route over a fresh direct Session. Returning it as
        ``via`` lets the application host callback objects in the same Session
        as the redeemed capability. ``via`` is resolved from the reply's own
        Host token, so concurrent and cached redeems remain correctly
        attributed. It is ``None`` for an ordinary reply or retired exporter.
        """
        self.guard_open()
        reply = await self.send(target, verb, args)
        via = self._host.exporter_for(reply) if isinstance(reply, Ref) else None
        if via is self:
            via = None
        return SendRedeemingResult(reply, via)

    async def tell(
        self,
        target: "Ref | RemotePromise",
        verb: str | None,
        args: "Optional[list]" = None,
    ) -> None:
        """Fire-and-forget eventual-send without allocating an answer.

        Returns once the deliver is queued, and the session's writer sends it.
        A wire failure already recorded on the session is raised.
        """
        self.guard_open()
        self._host.gc.drain_gc()
        await _dispatch_tell(self, target, verb, args if args is not None else ())
        self.raise_wire_failure()

    def set_exporter_locator(self, locator: "Optional[Locator]") -> None:
        """Override the exporter location with a complete typed locator.

        ``None`` restores the partner's signed location.
        """
        self.guard_open()
        if locator is None:
            _check_host(
                _host.glowcap_host_session_set_exporter_location(self._ptr, None)
            )
            return
        with _OwnedLocator.create(locator) as owned:
            _check_host(
                _host.glowcap_host_session_set_exporter_location(
                    self._ptr, owned.borrow_view()
                )
            )

    def partner_identity(self) -> PartnerIdentity:
        """Return the Python-owned identity facts proved by the handshake.

        The engine verifies the signature before the Session opens. Borrowed
        ABI views are copied before return, so this result does not depend on
        the Session's later lifetime.
        """
        self.guard_open()
        info = _PartnerIdentity()
        _check_host(
            _host.glowcap_host_session_partner_identity(
                self._ptr,
                ctypes.byref(info),
            )
        )

        def owned(ptr, length) -> bytes:
            return ctypes.string_at(ptr, length) if ptr and length else b""

        try:
            provenance = _provenance_from_abi(info.provenance)
        except ValueError as error:
            raise GlowcapError(_abi.ERR_INTERNAL, str(error)) from error

        return PartnerIdentity(
            session_key=owned(info.session_key, info.session_key_len),
            designator=owned(info.designator, info.designator_len).decode(
                errors="replace"
            ),
            locator_record=owned(info.locator_record, info.locator_record_len),
            provenance=provenance,
        )

    def bind_verified_channel_key(self, designator: str) -> None:
        """Bind transport-proved durable identity before the first peer byte.

        The realizer owns this evidence because glowcap does not open the
        socket. A second distinct identity is refused. Repeating the same fact
        is idempotent.
        """
        self.guard_open()
        raw = designator.encode()
        buf, ptr = _byte_buf(raw)
        _check_host(
            _host.glowcap_host_session_bind_verified_channel_key(
                self._ptr,
                ptr,
                len(raw),
            )
        )
        del buf

    def with_gc(self) -> "Session":
        """Opt this Session into distributed capability GC and return it.

        Capability occurrences projected through this Session then release
        their Host retain when Python reclaims the :class:`Ref`.
        """
        self._gc_enabled = True
        return cast("Session", self)

    def published_ref(self, name: str) -> "Ref | None":
        """Project the Host publication published under ``name`` onto this Session.

        This is the lazy Session projection for a Host publication. It
        returns ``None`` when no such name is published.
        """
        self.guard_open()
        data = name.encode()
        buf, ptr = _byte_buf(data)
        out = _Reference()
        try:
            rc = _host.glowcap_host_session_published_ref(
                self._ptr, ptr, len(data), ctypes.byref(out)
            )
        finally:
            del buf
        if rc == _abi.ERR_NOT_FOUND:
            return None
        _check_host(rc)
        ref = _ref_from_id(out.id)
        if ref.id not in self._hosted:
            ctx = self._host._publications.get(name)
            if ctx is not None:
                self._hosted[ref.id] = ctx
        return ref

    def release(self, ref: Ref) -> None:
        """Deterministically give back one application capability retain.

        The handle is spent after success. A capability from another Host or
        one already released is a caller error.
        """
        if ref.released:
            raise ValueError("capability already released")
        release_ref(self._host.raw, ref)
        self._host.gc.disarm(ref)
        ref._mark_released()
