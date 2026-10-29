"""Internal: the codec-neutral value and capability vocabulary.

The opaque application capability :class:`Ref` the
:class:`Session` surface hands back, the marshalling wrappers
(:class:`Symbol`, :class:`Keyword`, :class:`Set`, :class:`Tagged`), a
behavior's :class:`Forward` tail-forward, and the :data:`Argument` and
:data:`Behavior` type aliases. Pure data: no FFI, no I/O.
There is one value vocabulary from application through FFI. Re-exported from the
:mod:`glowcap` package. Import from there.
"""

from __future__ import annotations

import array
from dataclasses import dataclass
from typing import Callable, TypeAlias


_REF_MINT = object()


@dataclass(frozen=True, init=False)
class Ref:
    """An application capability: what :meth:`Session.fetch`,
    :meth:`Session.spawn`, and a :meth:`Session.send` reply hand back,
    and what ``send``/``tell`` accept as a target or argument.

    ``id`` is an opaque identity in the Host that produced the handle. It is
    never a wire position and does not reveal whether the target is local,
    remote, or handoff-routed. Python ``==`` and hashing compare only that
    immutable identity. Occurrence-local release and GC state do not change
    Target equality.
    """

    id: int

    def __init__(self, id: int, mint=None):
        if mint is not _REF_MINT:
            raise TypeError("Ref capabilities are minted by a glowcap Host")
        object.__setattr__(self, "id", id)

    @property
    def released(self) -> bool:
        """True once :meth:`Session.release` has given this capability back."""
        return getattr(self, "_released_flag", False)
    def _mark_released(self) -> None:
        """Mark this handle spent. Called by :meth:`Session.release`."""
        object.__setattr__(self, "_released_flag", True)

    def _live(self) -> "Ref":
        """Return this capability for ABI marshalling.

        Refused once the capability has been released. Release
        spends this occurrence's retain. Another occurrence may keep the same
        Host identity live, so local dispatch and ABI projection both check
        this occurrence before use.
        """
        if self.released:
            raise ValueError(
                "this capability was released and is no longer usable"
            )
        return self


def _ref_from_id(id: int) -> Ref:
    """Binding-internal Host mint. Absent from package exports."""
    return Ref(id, _REF_MINT)


class Symbol(str):
    """A string that marshals as an OCapN symbol rather than a string."""


class Keyword(str):
    """A string that marshals as an OCapN keyword."""


@dataclass(frozen=True)
class ErrorValue:
    """A fulfilled OCapN Error value.

    Returning this is data. Raising an exception is the separate operation
    that breaks a reply.
    """

    message: str


class Set(list):
    """A list that marshals as an OCapN set (elements may be unhashable)."""


@dataclass(frozen=True)
class Tagged:
    """An OCapN tagged record: a tag symbol over a value list."""

    tag: str
    value: list


@dataclass(frozen=True)
class Struct:
    """An OCapN Struct: unordered, uniquely named String fields."""

    entries: list[tuple[str, "Argument"]]


class Forward:
    """A behavior's tail-forward of its answer to another capability: the
    binding's `Turn.forward` (ADR-0016). Return ``Forward(target, verb, args)``
    from a behavior and the answer resolves from ``target <- verb(args)``
    instead of from a value: a target this side hosts composes in process, a
    far target defers the answer until the forwarded reply settles. It is the
    whole mechanism behind a caretaker/attenuator: each is an ordinary actor
    whose behavior forwards (or raises to refuse), so the proxy is a plain
    :class:`Ref` you delegate and may call locally or over the wire alike."""

    __slots__ = ("target", "verb", "args")

    def __init__(self, target: "Ref", verb: str, args=None):
        self.target = target
        self.verb = verb
        self.args = list(args or [])


# An argument is a plain Python value or a wrapper:
#   int, float, bool, bytes, str, Symbol, Keyword, ErrorValue, None (void), Ref,
#   list, Set, Tagged, Struct, and ``array.array('q')``, a list of integers
#   sent as one run of words (a peer's list of integers arrives as a list).
#   A RemotePromise this Host returned is passable to ``send``/``tell`` in
#   any state (ADR-0068): the Host passes it as a capability for its answer.
#   A peer's promise arrives as a Ref, and an object this side hosts receives
#   the RemotePromise itself.
Argument: TypeAlias = (
    int | float | bool | bytes | str | Symbol | Keyword | ErrorValue | None | Ref | list | Set | Tagged | Struct | array.array[int]
)

# An actor: handle a ``(verb, args)`` call and return a reply (``None`` is the
# OCapN void). ``args`` may contain :class:`Ref`s (capabilities handed to you);
# raise to break the caller's promise, or return a :class:`Forward` to
# tail-forward the answer.
Behavior: TypeAlias = Callable[[str, "list[Argument]"], "Argument | Forward | None"]
