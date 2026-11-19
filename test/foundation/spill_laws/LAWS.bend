import Base

# A geometric growth step doubles capacity and can take more when a single
# append needs it. This models successful unsaturated growth on one append
# episode. Compaction and shrinking have separate costs.
type Balance is Data:
  Balance{capacity: Nat, moved: Nat}

def capacity(balance: Balance) -> Nat:
  match balance:
    case Balance{cap, bytes}: cap

def moved(balance: Balance) -> Nat:
  match balance:
    case Balance{cap, bytes}: bytes

def grow(+cap: Nat, extra: Nat) -> Nat:
  Nat.add(cap, Nat.add(cap, extra))

def step(balance: Balance, extra: Nat) -> Balance:
  match balance:
    case Balance{+cap, bytes}: Balance{grow(cap, extra), Nat.add(cap, bytes)}

def run(+extras: List<&2, Nat>, balance: Balance) -> Balance:
  match extras:
    case Nil{}: balance
    case extra <> rest: run(rest, step(balance, extra))

def margin(+extras: List<&2, Nat>, spare: Nat) -> Nat:
  match extras:
    case Nil{}: spare
    case extra <> rest: margin(rest, Nat.add(spare, extra))

law reallocations_keep_copy_margin:
  for +extras: List<&2, Nat>
  for +copied: Nat
  for +spare: Nat
  {capacity(run(extras, Balance{Nat.add(copied, spare), copied})) ==
   Nat.add(moved(run(extras, Balance{Nat.add(copied, spare), copied})), margin(extras, spare)) : Nat}

law a_positive_margin_stays_positive:
  for +extras: List<&2, Nat>
  for +spare: Nat
  {Nat.is_lt(0n, margin(extras, 1n+spare)) == True{} : Bool}

law cumulative_copy_stays_below_capacity:
  for +extras: List<&2, Nat>
  for +copied: Nat
  for +spare: Nat
  {Nat.is_lt(moved(run(extras, Balance{Nat.add(copied, 1n+spare), copied})),
             capacity(run(extras, Balance{Nat.add(copied, 1n+spare), copied}))) == True{} : Bool}
