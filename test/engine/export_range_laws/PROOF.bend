import Base
import ./LAWS.bend as L

law opposing_bounds:
  for +split: Nat
  for +pos: Nat
  for +continuation: Bool
  {Bool.and(Nat.is_lt(pos, split), Bool.and(Nat.is_le(split, pos), continuation)) == False{} : Bool}

def opposing_bounds(split, pos, continuation):
  match split pos:
    case 0n 0n: {==}
    case 0n 1n+p: {==}
    case 1n+s 0n:
      match continuation:
        case False{}: {==}
        case True{}: {==}
    case 1n+s 1n+p: opposing_bounds(s, p, continuation)

def L.adjacent_ranges_are_disjoint(base, span, following_span, pos):
  match base pos:
    case 0n 0n: opposing_bounds(span, 0n, Nat.is_lt(0n, following_span))
    case 0n 1n+p:
      opposing_bounds(span, 1n+p, Nat.is_lt(Nat.sub(1n+p, span), following_span))
    case 1n+b 0n: {==}
    case 1n+b 1n+p: L.adjacent_ranges_are_disjoint(b, span, following_span, p)
