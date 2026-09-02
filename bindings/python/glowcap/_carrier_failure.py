"""Typed projection of the native carrier failure location."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Optional

from . import _constants as _c
from ._errors import GlowcapError


class CarrierPhase(Enum):
    RESOLVE = "resolve"
    CONNECT = "connect"
    SECURE_HANDSHAKE = "secure_handshake"
    WEBSOCKET_UPGRADE = "websocket_upgrade"
    REGISTRATION = "registration"
    RECEIVE = "receive"
    TRANSMIT = "transmit"
    SHUTDOWN = "shutdown"


@dataclass(frozen=True)
class CarrierFailure:
    phase: CarrierPhase
    verification_flags: int = 0
    peer_alert: Optional[int] = None
    engine_code: Optional[int] = None


_PHASES = {
    _c.CARRIER_PHASE_RESOLVE: CarrierPhase.RESOLVE,
    _c.CARRIER_PHASE_CONNECT: CarrierPhase.CONNECT,
    _c.CARRIER_PHASE_SECURE_HANDSHAKE: CarrierPhase.SECURE_HANDSHAKE,
    _c.CARRIER_PHASE_WEBSOCKET_UPGRADE: CarrierPhase.WEBSOCKET_UPGRADE,
    _c.CARRIER_PHASE_REGISTRATION: CarrierPhase.REGISTRATION,
    _c.CARRIER_PHASE_RECEIVE: CarrierPhase.RECEIVE,
    _c.CARRIER_PHASE_TRANSMIT: CarrierPhase.TRANSMIT,
    _c.CARRIER_PHASE_SHUTDOWN: CarrierPhase.SHUTDOWN,
}


def _decode(
    phase: int,
    detail_flags: int,
    verification_flags: int,
    peer_alert: int,
    engine_code: int,
) -> Optional[CarrierFailure]:
    if phase == _c.CARRIER_PHASE_NONE:
        if detail_flags == verification_flags == peer_alert == engine_code == 0:
            return None
        raise _invalid("carrier detail without a carrier phase")
    decoded = _PHASES.get(phase)
    if decoded is None:
        raise _invalid(f"unknown carrier phase {phase}")
    known = _c.CARRIER_DETAIL_PEER_ALERT | _c.CARRIER_DETAIL_ENGINE_CODE
    peer_present = bool(detail_flags & _c.CARRIER_DETAIL_PEER_ALERT)
    engine_present = bool(detail_flags & _c.CARRIER_DETAIL_ENGINE_CODE)
    if (
        detail_flags & ~known
        or (not peer_present and peer_alert != 0)
        or (peer_present and peer_alert > 0xFF)
        or (not engine_present and engine_code != 0)
    ):
        raise _invalid("inconsistent carrier failure detail")
    return CarrierFailure(
        decoded,
        verification_flags,
        peer_alert if peer_present else None,
        engine_code if engine_present else None,
    )


def _invalid(detail: str) -> GlowcapError:
    return GlowcapError(_c.ERR_INTERNAL, f"driver returned {detail}")
