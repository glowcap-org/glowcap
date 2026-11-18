import Base
import ./LAWS.bend as L

# Floor and ceiling advance together when all three values have a predecessor.
def numeric_law(+d: L.Direction, +c: Nat, +a: Nat, +b: Nat) -> Type:
  {L.includes(d, c, L.tighter(d, a, b)) == Bool.and(L.includes(d, c, a), L.includes(d, c, b)) : Bool}

def and_true(x: Bool) -> {x == Bool.and(x, True{}) : Bool}:
  match x:
    case False{}: {==}
    case True{}: {==}

def and_false(x: Bool) -> {False{} == Bool.and(x, False{}) : Bool}:
  match x:
    case False{}: {==}
    case True{}: {==}

def numeric(+c: Nat, +a: Nat, +b: Nat) -> numeric_law(L.Floor{}, c, a, b) & numeric_law(L.Ceiling{}, c, a, b):
  match c a b:
    case 0n 0n 0n: ({==}, {==})
    case 0n 0n 1n+y: ({==}, {==})
    case 0n 1n+x 0n: ({==}, {==})
    case 0n 1n+x 1n+y: ({==}, {==})
    case 1n+z 0n 0n: ({==}, {==})
    case 1n+z 0n 1n+y: ({==}, {==})
    case 1n+z 1n+x 0n: (and_true(Nat.is_ge(z, x)), and_false(Nat.is_le(z, x)))
    case 1n+z 1n+x 1n+y: numeric(z, x, y)

def at(d: L.Direction, +c: Nat, +a: Nat, +b: Nat) -> numeric_law(d, c, a, b):
  match d:
    case L.Floor{}: Pair.fst(numeric_law(L.Floor{}, c, a, b), numeric_law(L.Ceiling{}, c, a, b), numeric(c, a, b))
    case L.Ceiling{}: Pair.snd(numeric_law(L.Floor{}, c, a, b), numeric_law(L.Ceiling{}, c, a, b), numeric(c, a, b))

def bounded(d: L.Direction, child: L.Bound, +a: Nat, +b: Nat) -> {
  L.fits(d, child, L.At{L.tighter(d, a, b)}) == Bool.and(L.fits(d, child, L.At{a}), L.fits(d, child, L.At{b})) : Bool}:
  match child:
    case L.Open{}: {==}
    case L.At{c}: at(d, c, a, b)

def L.intersection(d, child, a, b):
  match a b:
    case L.Open{} L.Open{}: {==}
    case L.Open{} L.At{y}: {==}
    case L.At{x} L.Open{}: and_true(L.fits(d, child, L.At{x}))
    case L.At{x} L.At{y}: bounded(d, child, x, y)

def L.delegation(d, parents, child, held):
  match parents:
    case Nil{}: {==}
    case head <> rest:
      %L.intersection(d, child, held, head) : {
        L.fits(d, child, L.chain(d, rest, L.meet(d, held, head))) == L.every_parent(d, rest, child, _) : Bool}
      L.delegation(d, rest, child, L.meet(d, held, head))
