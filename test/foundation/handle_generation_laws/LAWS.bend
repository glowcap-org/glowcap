import Base

# Remaining counts fresh generations the same index can still mint.
type Row is Data:
  Live{generation: Nat, remaining: Nat}
  Retired{}

def advances(steps: Nat, row: Row) -> Row:
  match steps row:
    case 0n _: row
    case 1n+_ Retired{}: Retired{}
    case 1n+_ Live{_, 0n}: Retired{}
    case 1n+steps Live{generation, 1n+remaining}: advances(steps, Live{1n+generation, remaining})

def recognizes(old: Nat, row: Row) -> Bool:
  match row:
    case Retired{}: False{}
    case Live{generation, _}: Nat.is_eq(old, generation)

law a_freed_generation_never_matches:
  for +old: Nat
  for +remaining: Nat
  for +steps: Nat
  {recognizes(old, advances(1n+steps, Live{old, remaining})) == False{} : Bool}
