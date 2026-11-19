import Base
import ./LAWS.bend as L

law add_associates:
  for +a: Nat
  for +b: Nat
  for +c: Nat
  {Nat.add(Nat.add(a, b), c) == Nat.add(a, Nat.add(b, c)) : Nat}

def add_associates(a, b, c):
  match a:
    case 0n: {==}
    case 1n+x:
      %add_associates(x, b, c) : {1n+Nat.add(Nat.add(x, b), c) == 1n+_ : Nat}
      {==}

law growth_margin:
  for +cap: Nat
  for +copied: Nat
  for +spare: Nat
  for +extra: Nat
  {Nat.add(cap, Nat.add(Nat.add(copied, spare), extra)) ==
   Nat.add(Nat.add(cap, copied), Nat.add(spare, extra)) : Nat}

def growth_margin(cap, copied, spare, extra):
  Equal.trans(Nat,
    Nat.add(cap, Nat.add(Nat.add(copied, spare), extra)),
    Nat.add(cap, Nat.add(copied, Nat.add(spare, extra))),
    Nat.add(Nat.add(cap, copied), Nat.add(spare, extra)),
    Equal.cong(Nat, Nat, n => Nat.add(cap, n), Nat.add(Nat.add(copied, spare), extra),
      Nat.add(copied, Nat.add(spare, extra)), add_associates(copied, spare, extra)),
    Equal.sym(Nat, Nat.add(Nat.add(cap, copied), Nat.add(spare, extra)),
      Nat.add(cap, Nat.add(copied, Nat.add(spare, extra))), add_associates(cap, copied, Nat.add(spare, extra))))

def L.reallocations_keep_copy_margin(extras, copied, spare):
  match extras:
    case Nil{}: {==}
    case extra <> rest:
      +cap = Nat.add(copied, spare)
      +paid = Nat.add(cap, copied)
      +next_spare = Nat.add(spare, extra)
      %Equal.sym(Nat, L.grow(cap, extra), Nat.add(paid, next_spare), growth_margin(cap, copied, spare, extra)) : {
        L.capacity(L.run(rest, L.Balance{_, paid})) ==
        Nat.add(L.moved(L.run(rest, L.Balance{_, paid})), L.margin(rest, next_spare)) : Nat}
      L.reallocations_keep_copy_margin(rest, paid, next_spare)

def L.a_positive_margin_stays_positive(extras, spare):
  match extras:
    case Nil{}: {==}
    case extra <> rest: L.a_positive_margin_stays_positive(rest, Nat.add(spare, extra))

law positive_gap_is_larger:
  for +value: Nat
  for +gap: Nat
  for positive: {Nat.is_lt(0n, gap) == True{} : Bool}
  {Nat.is_lt(value, Nat.add(value, gap)) == True{} : Bool}

def positive_gap_is_larger(value, gap, positive):
  match value:
    case 0n: positive
    case 1n+rest: positive_gap_is_larger(rest, gap, positive)

def L.cumulative_copy_stays_below_capacity(extras, copied, spare):
  +final = L.run(extras, L.Balance{Nat.add(copied, 1n+spare), copied})
  +bytes = L.moved(final)
  +headroom = L.margin(extras, 1n+spare)
  Equal.trans(Bool, Nat.is_lt(bytes, L.capacity(final)), Nat.is_lt(bytes, Nat.add(bytes, headroom)), True{},
    Equal.cong(Nat, Bool, cap => Nat.is_lt(bytes, cap), L.capacity(final), Nat.add(bytes, headroom),
      L.reallocations_keep_copy_margin(extras, copied, 1n+spare)),
    positive_gap_is_larger(bytes, headroom, L.a_positive_margin_stays_positive(extras, spare)))
