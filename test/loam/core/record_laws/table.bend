import Base
import ./LAWS.bend as L
import ./PROOF.bend as Proof

def row(before: Nat, after: Nat) -> String:
  Nat.show(before) ++ " " ++ Nat.show(after) ++ "\n"

# Normalize already crossed decimal thresholds to zero, and the one under
# test to one. The threshold law applies at the original positions.
def decimal_rows(remaining: Nat, +crossed: List<&2, Nat>) -> String:
  match remaining:
    case 0n: ""
    case 1n+more:
      +cuts: List<&2, Nat> = 1n <> crossed
      row(Nat.sub(L.envelope(cuts, 0n, 0n, 0n, 0n), 1n),
          Nat.sub(L.envelope(cuts, 1n, 0n, 0n, 0n), 2n)) ++ decimal_rows(more, 0n <> crossed)

# Decimal digits, least significant first. The largest intermediate is 19.
def double(digits: List<&2, Nat>, carry: Nat) -> List<&2, Nat>:
  match digits:
    case Nil{}:
      match carry:
        case 0n: Nil{}
        case 1n+p: (1n+p) <> Nil{}
    case digit <> rest:
      +sum = Nat.add(Nat.double(digit), carry)
      Nat.mod(sum, 10n) <> double(rest, Nat.div(sum, 10n))

# The next pair is (2 * before + 1, 2 * after).
def binary_rows(remaining: Nat, +before: List<&2, Nat>, +after: List<&2, Nat>) -> String:
  match remaining:
    case 0n: ""
    case 1n+more:
      row(List.length(&2, Nat, before), List.length(&2, Nat, after)) ++
      binary_rows(more, double(before, 1n), double(after, 0n))

def main() -> IO(Unit):
  IO.write(decimal_rows(19n, Nil{}) ++ "\n" ++
           binary_rows(63n, 1n <> Nil{}, 2n <> Nil{}) ++ "\n" ++
           row(1n, 20n) ++ Nat.show(Nat.sub(L.envelope(Nil{}, 0n, 2n, 1n, 0n), 2n)))
