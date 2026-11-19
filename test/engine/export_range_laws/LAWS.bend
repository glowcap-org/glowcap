import Base

def contains(+base: Nat, span: Nat, +pos: Nat) -> Bool:
  Bool.and(Nat.is_le(base, pos), Nat.is_lt(Nat.sub(pos, base), span))

law adjacent_ranges_are_disjoint:
  for +base: Nat
  for +span: Nat
  for +following_span: Nat
  for +pos: Nat
  {Bool.and(contains(base, span, pos), contains(Nat.add(base, span), following_span, pos)) == False{} : Bool}
