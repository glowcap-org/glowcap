"""Owned Python shape of one borrowed native driver event."""

from __future__ import annotations

from typing import Optional

from ._carrier_failure import CarrierFailure


class LoopEvent:
    """One drained event after its borrowed C views have been copied out."""

    __slots__ = (
        "kind",
        "primary_result",
        "secondary_result",
        "secondary_count",
        "carrier_failure",
        "operation_id",
        "listener_id",
        "session",
        "primary_name",
        "secondary_name",
        "settled_ok",
        "decoded",
    )

    def __init__(
        self,
        kind: int,
        primary_result: int,
        secondary_result: int,
        secondary_count: int,
        operation_id: int,
        listener_id: int,
        session: Optional[int],
        primary_name: str = "",
        secondary_name: str = "",
        settled_ok: bool = False,
        decoded: object = None,
        carrier_failure: Optional[CarrierFailure] = None,
    ) -> None:
        self.kind = kind
        self.primary_result = primary_result
        self.secondary_result = secondary_result
        self.secondary_count = secondary_count
        self.carrier_failure = carrier_failure
        self.operation_id = operation_id
        self.listener_id = listener_id
        self.session = session
        self.primary_name = primary_name
        self.secondary_name = secondary_name
        self.settled_ok = settled_ok
        self.decoded = decoded
