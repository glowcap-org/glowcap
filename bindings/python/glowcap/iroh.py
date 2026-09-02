"""Idiomatic Python API for Glowcap's optional encrypted-QUIC transport.

The public module is deliberately only a facade. ``_iroh_native`` owns the C
archive endpoint and provider lifecycle; ``_iroh_async`` projects that owner
onto asyncio and the ordinary Session API. Neither layer owns CapTP semantics.
"""

from ._iroh_async import (
    IrohServer,
    _IrohLoop as _IrohLoop,
    connector,
    dial_locator_for_relay,
    listen,
)
from ._iroh_native import (
    IrohConfig,
    IrohConnection,
    IrohNetlayer,
    Reachability,
    adopt_loop_provider as adopt_loop_provider,
    locator,
    provider,
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
