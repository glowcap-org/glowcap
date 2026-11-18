import Base
import ./LAWS.bend as L
import ./PROOF.bend as Proof

def equal(a: L.Bound, b: L.Bound) -> Bool:
  match a b:
    case L.Open{} L.Open{}: True{}
    case L.At{x} L.At{y}: Nat.is_eq(x, y)
    case _ _: False{}

def bit(value: Bool) -> String:
  Bool.pick(String, value, "1", "0")

def compare(+d: L.Direction, +child: L.Bound, +parent: L.Bound) -> String:
  bit(L.fits(d, child, parent)) ++ bit(equal(L.meet(d, child, parent), child)) ++
  bit(L.admits(d, child, parent))

# Zero and one stand for the two endpoints in the Zig witness.
def row(+d: L.Direction) -> String:
  +low: L.Bound = L.At{0n}
  +high: L.Bound = L.At{1n}
  compare(d, L.Open{}, L.Open{}) ++ " " ++ compare(d, high, L.Open{}) ++ " " ++
  compare(d, L.Open{}, low) ++ " " ++ compare(d, L.Open{}, high) ++ " " ++
  compare(d, low, high) ++ " " ++
  compare(d, high, high) ++ " " ++ compare(d, high, low)

def main() -> IO(Unit):
  IO.print("lower_bound " ++ row(L.Floor{}) ++ "\nupper_bound " ++ row(L.Ceiling{}))
