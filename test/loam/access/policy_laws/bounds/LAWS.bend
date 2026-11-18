import Base

type Bound is Data:
  Open{}
  At{value: Nat}

type Direction is Data:
  Floor{}
  Ceiling{}

def includes(d: Direction, child: Nat, parent: Nat) -> Bool:
  match d:
    case Floor{}: Nat.is_ge(child, parent)
    case Ceiling{}: Nat.is_le(child, parent)

def tighter(d: Direction, a: Nat, b: Nat) -> Nat:
  match d:
    case Floor{}: Nat.max(a, b)
    case Ceiling{}: Nat.min(a, b)

def within(d: Direction, child: Bound, limit: Nat) -> Bool:
  match child:
    case Open{}: False{}
    case At{value}: includes(d, value, limit)

def fits(d: Direction, child: Bound, parent: Bound) -> Bool:
  match parent:
    case Open{}: True{}
    case At{limit}: within(d, child, limit)

def meet(d: Direction, a: Bound, b: Bound) -> Bound:
  match a b:
    case Open{} _: b
    case At{x} Open{}: a
    case At{x} At{y}: At{tighter(d, x, y)}

law intersection:
  for +d: Direction
  for +child: Bound
  for +a: Bound
  for +b: Bound
  {fits(d, child, meet(d, a, b)) == Bool.and(fits(d, child, a), fits(d, child, b)) : Bool}

# An omitted fact places no demand on the policy.
def admits(d: Direction, fact: Bound, limit: Bound) -> Bool:
  match fact:
    case Open{}: True{}
    case At{value}: fits(d, At{value}, limit)

law admission_intersection:
  for +d: Direction
  for +fact: Bound
  for +a: Bound
  for +b: Bound
  {admits(d, fact, meet(d, a, b)) == Bool.and(admits(d, fact, a), admits(d, fact, b)) : Bool}

def chain(+d: Direction, parents: List<&2, Bound>, held: Bound) -> Bound:
  match parents:
    case Nil{}: held
    case head <> rest: chain(d, rest, meet(d, held, head))

def every_parent(+d: Direction, parents: List<&2, Bound>, +child: Bound, held: Bool) -> Bool:
  match parents:
    case Nil{}: held
    case head <> rest: every_parent(d, rest, child, Bool.and(held, fits(d, child, head)))

law delegation:
  for +d: Direction
  for +parents: List<&2, Bound>
  for +child: Bound
  for +held: Bound
  {fits(d, child, chain(d, parents, held)) == every_parent(d, parents, child, fits(d, child, held)) : Bool}
