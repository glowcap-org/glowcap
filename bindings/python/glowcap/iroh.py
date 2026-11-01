"""Idiomatic Python API for Glowcap's optional encrypted-QUIC transport.

The public module is only a facade. ``_iroh_ffi`` owns the C
archive endpoint and provider lifecycle. ``_iroh_async`` projects that owner
onto asyncio and the ordinary Session API. Neither layer owns CapTP semantics.
"""

from ._iroh_async import (
    IrohServer,
    connector,
    dial_locator_for_relay,
    listen,
)
from ._iroh_async import (
    _IrohLoop as _IrohLoop,
)
from ._iroh_ffi import (
    IrohConfig,
    IrohConnection,
    IrohNetlayer,
    Reachability,
    locator,
    provider,
)
from ._iroh_ffi import (
    adopt_loop_provider as adopt_loop_provider,
)

__all__ = [
    "Reachability",
    "IrohServer",
    "IrohNetlayer",
    "IrohConfig",
    "IrohConnection",
    "listen",
    "dial_locator_for_relay",
    "locator",
    "provider",
    "connector",
]
