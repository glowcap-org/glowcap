import Base

def add_right_zero(+a: Nat) -> {Nat.add(a, 0n) == a : Nat}:
  match a:
    case 0n: {==}
    case 1n+p:
      %add_right_zero(p) : {1n+Nat.add(p, 0n) == 1n+_ : Nat}
      {==}

def add_right_successor(+a: Nat, +b: Nat) -> {Nat.add(a, 1n+b) == 1n+Nat.add(a, b) : Nat}:
  match a:
    case 0n: {==}
    case 1n+p:
      %add_right_successor(p, b) : {1n+Nat.add(p, 1n+b) == 1n+_ : Nat}
      {==}

def score_swap(+a: Nat, +b: Nat) -> {Nat.add(a, b) == Nat.add(b, a) : Nat}:
  match a:
    case 0n: Equal.sym(Nat, Nat.add(b, 0n), b, add_right_zero(b))
    case 1n+p:
      Equal.trans(Nat, 1n+Nat.add(p, b), 1n+Nat.add(b, p), Nat.add(b, 1n+p),
        Equal.cong(Nat, Nat, x => 1n+x, Nat.add(p, b), Nat.add(b, p), score_swap(p, b)),
        Equal.sym(Nat, Nat.add(b, 1n+p), 1n+Nat.add(b, p), add_right_successor(b, p)))


def precedes(+cost: Nat, +other: Nat, id_first: Bool) -> Bool:
  Bool.or(Nat.is_lt(cost, other), Bool.and(Nat.is_eq(cost, other), id_first))

law ranking_survives_swap:
  for +a: Nat
  for +b: Nat
  for +c: Nat
  for +d: Nat
  for +id_first: Bool
  {precedes(Nat.add(a, b), Nat.add(c, d), id_first) == precedes(Nat.add(b, a), Nat.add(d, c), id_first) : Bool}

def ranking_survives_swap(a, b, c, d, id_first):
  %score_swap(a, b) : {precedes(Nat.add(a, b), Nat.add(c, d), id_first) == precedes(_, Nat.add(d, c), id_first) : Bool}
  %score_swap(c, d) : {precedes(Nat.add(a, b), Nat.add(c, d), id_first) == precedes(Nat.add(a, b), _, id_first) : Bool}
  {==}
