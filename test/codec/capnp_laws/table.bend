import Base
import ./LAWS.bend as Bits
import ./PROOF.bend as Proof

def render(n: Nat, word: Word(n)) -> String:
  match n:
    case 0n: ""
    case 1n+p:
      match word:
        case WCon{bit, tail}: Bool.pick(String, bit, "1", "0") ++ render(p, tail)

def render_fields(+a: Nat, +b: Nat, fields: Word(a) & Word(b)) -> String:
  (lo, hi) = fields
  render(a, lo) ++ " " ++ render(b, hi)

def fields(+a: Nat, +b: Nat, word: Word(Nat.add(a, b))) -> String:
  render_fields(a, b, Bits.split(a, b, word))

def row_fields(+list: Bool, +kind: Word(2n), encoded: Word(64n), projection: Word(30n) & Word(32n)) -> String:
  (offset, +sizes) = projection
  section = Bool.pick(String, list, fields(3n, 29n, sizes), fields(16n, 16n, sizes))
  render(2n, kind) ++ " " ++ render(32n, Bits.extend(29n, 2n, offset)) ++
  " " ++ section ++ " " ++ render(64n, encoded) ++ "\n"

def row(+list: Bool, +payload: Word(62n)) -> String:
  +kind: Word(2n) = WCon{list, WCon{False{}, WNil{}}}
  row_fields(list, kind, Bits.join(2n, 62n, kind, payload), Bits.split(30n, 32n, payload))

def basis(n: Nat, +list: Bool, +payload: Word(62n)) -> String:
  match n:
    case 0n: ""
    case 1n+p: row(list, payload) ++ basis(p, list, Word.shl(62n, payload))

def alternate(n: Nat, +bit: Bool) -> Word(n):
  match n:
    case 0n: WNil{}
    case 1n+p: WCon{bit, alternate(p, Bool.not(bit))}

def rows(+list: Bool) -> String:
  row(list, Word.zero(62n)) ++
  basis(62n, list, WCon{True{}, Word.zero(61n)}) ++
  row(list, Bits.repeat(62n, True{})) ++
  row(list, Bits.join(29n, 33n, alternate(29n, True{}), WCon{True{}, alternate(32n, True{})}))

def main() -> IO(Unit):
  IO.write(rows(False{}) ++ rows(True{}))
