import Base

# The decimal band starts at one digit. Each crossed power of ten
# contributes one more digit.
def crossing(cut: Nat, length: Nat) -> Nat:
  match cut length:
    case 0n _: 1n
    case 1n+c 0n: 0n
    case 1n+c 1n+n: crossing(c, n)

def digits(cuts: List<&2, Nat>, +length: Nat) -> Nat:
  match cuts:
    case Nil{}: 1n
    case cut <> rest: Nat.add(crossing(cut, length), digits(rest, length))

def payload_size(+length: Nat, cuts: List<&2, Nat>) -> Nat:
  Nat.add(length, 1n+digits(cuts, length))

law decimal_width_monotone:
  for +cuts: List<&2, Nat>
  for +length: Nat
  for +extra: Nat
  {Nat.is_ge(digits(cuts, Nat.add(length, extra)), digits(cuts, length)) == True{} : Bool}

law payload_size_monotone:
  for +cuts: List<&2, Nat>
  for +length: Nat
  for +extra: Nat
  {Nat.is_ge(payload_size(Nat.add(length, extra), cuts), payload_size(length, cuts)) == True{} : Bool}

law threshold_transition:
  for +before: Nat
  {crossing(1n+before, before) == 0n : Nat} &
  {crossing(1n+before, 1n+before) == 1n : Nat}

# The header estimate includes the longest revision and the chosen schema.
# Every edge encodes to the same width. Overhead also includes the checksum.
def envelope(cuts: List<&2, Nat>, length: Nat, edges: Nat, edge_width: Nat, overhead: Nat) -> Nat:
  Nat.add(payload_size(length, cuts), Nat.add(Nat.mul(edges, edge_width), overhead))

law envelope_ceiling:
  for +cuts: List<&2, Nat>
  for +length: Nat
  for +more_payload: Nat
  for +edges: Nat
  for +more_edges: Nat
  for +edge_width: Nat
  for +overhead: Nat
  for +more_overhead: Nat
  {Nat.is_ge(envelope(cuts, Nat.add(length, more_payload), Nat.add(edges, more_edges), edge_width, Nat.add(overhead, more_overhead)),
             envelope(cuts, length, edges, edge_width, overhead)) == True{} : Bool}
