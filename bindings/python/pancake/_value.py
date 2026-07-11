"""Internal: the codec-neutral value and reference vocabulary.

The wire reference wrappers (:class:`Near`, :class:`Far`, :class:`Promise`,
:class:`Sturdy`, :class:`Broken`), the application capability :class:`Ref` the
:class:`Connection` surface hands back, the marshalling wrappers
(:class:`Symbol`, :class:`Keyword`, :class:`Set`, :class:`Tagged`), a
behavior's :class:`Forward` tail-forward, the :data:`Argument` /
:data:`Value` / :data:`Behavior` type aliases, and the lower/lift walk between
the two vocabularies. Pure data: no FFI, no I/O. Re-exported from the
:mod:`pancake` package; import from there.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Optional, TypeAlias

@dataclass(frozen=True)
class Near:
    """A local export this connection hosts."""

    id: int
    promise: bool = False


@dataclass(frozen=True)
class Far:
    """A partner-hosted capability this side holds — on the application
    surface, a node-unique token (ADR-0069) the host routes to its home
    connection and real wire import."""

    id: int
    promise: bool = False


@dataclass(frozen=True)
class Promise:
    """A pipeline promise on an answer position, as a delivered argument."""

    answer: int


@dataclass(frozen=True)
class Sturdy:
    pass


@dataclass(frozen=True)
class Broken:
    pass


Reference: TypeAlias = Near | Far | Promise | Sturdy | Broken


@dataclass(frozen=True)
class Ref:
    """An application capability: what :meth:`Connection.fetch`,
    :meth:`Connection.spawn`, and a :meth:`Connection.send` reply hand back,
    and what ``send``/``tell`` accept as a target or argument.

    It names a local actor this connection hosts (carrying the ``Near`` export
    it marshals to) or a far capability the host holds (carrying its ``Far``
    token). Pass it as a ``send`` argument and it marshals to the right wire
    reference automatically.
    """

    far: Optional[Far] = None
    near: Optional[Near] = None

    def _wire(self) -> Reference:
        """The wire reference to marshal this capability to: a local actor's
        ``Near`` export, else the ``Far`` token it names."""
        if self.near is not None:
            return self.near
        if self.far is not None:
            return self.far
        from ._constants import ERR_UNSUPPORTED_VALUE
        from ._errors import PancakeError

        raise PancakeError(ERR_UNSUPPORTED_VALUE, "this ref has no wire reference to marshal")


class Symbol(str):
    """A string that marshals as an OCapN symbol rather than a string."""


class Keyword(str):
    """A string that marshals as an OCapN keyword."""


class Set(list):
    """A list that marshals as an OCapN set (elements may be unhashable)."""


@dataclass(frozen=True)
class Tagged:
    """An OCapN tagged record: a tag symbol over a value list."""

    tag: str
    value: list


class Forward:
    """A behavior's tail-forward of its answer to another capability — the
    binding's `Turn.forward` (ADR-0064). Return ``Forward(target, verb, args)``
    from a behavior and the answer resolves from ``target <- verb(args)``
    instead of from a value: a target this side hosts composes in process, a
    far target defers the answer until the forwarded reply settles. It is the
    whole mechanism behind a caretaker/attenuator — each is an ordinary actor
    whose behavior forwards (or raises to refuse), so the proxy is a plain
    :class:`Ref` you delegate and may call locally or over the wire alike."""

    __slots__ = ("target", "verb", "args")

    def __init__(self, target: "Ref", verb: str, args=None):
        self.target = target
        self.verb = verb
        self.args = list(args or [])


# An argument is a native Python value or a wrapper:
#   int, float, bool, bytes, str, Symbol, Keyword, None (void), Reference, list,
#   Set, Tagged.
Argument: TypeAlias = int | float | bool | bytes | str | Symbol | Keyword | None | Reference | list | Set | Tagged

# An application value mirrors an Argument but carries a capability as a `Ref`
# (the binding marshals it to/from a wire reference at the boundary), so an app
# works with capabilities as ordinary values; this is the vocabulary the
# application-surface `Connection` speaks.
Value: TypeAlias = "int | float | bool | bytes | str | Symbol | Keyword | None | Ref | list | Set | Tagged"

# An actor: handle a ``(verb, args)`` call and return a reply (``None`` is the
# OCapN void). ``args`` may contain :class:`Ref`s (capabilities handed to you);
# raise to break the caller's promise, or return a :class:`Forward` to
# tail-forward the answer.
Behavior: TypeAlias = Callable[[str, "list[Value]"], "Value | Forward | None"]


def _lower_value(value):
    """Lower an application value to the wire vocabulary: a :class:`Ref`
    becomes its wire reference, recursing into the container shapes a
    capability can hide in."""
    if isinstance(value, Ref):
        return value._wire()
    if isinstance(value, Set):  # before list, Set subclasses list
        return Set(_lower_value(v) for v in value)
    if isinstance(value, Tagged):
        return Tagged(value.tag, [_lower_value(v) for v in value.value])
    if isinstance(value, list):
        return [_lower_value(v) for v in value]
    return value


def _lift_value(value):
    """Lift a wire value to the application vocabulary: a capability reference
    becomes a :class:`Ref`, recursing into containers."""
    if isinstance(value, Far):
        return Ref(far=value)
    if isinstance(value, Near):
        return Ref(near=value)
    if isinstance(value, Set):  # before list, Set subclasses list
        return Set(_lift_value(v) for v in value)
    if isinstance(value, Tagged):
        return Tagged(value.tag, [_lift_value(v) for v in value.value])
    if isinstance(value, list):
        return [_lift_value(v) for v in value]
    return value
