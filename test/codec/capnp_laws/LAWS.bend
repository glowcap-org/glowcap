import Base

# Bend Word stores the least-significant bit first.
def join(low: Nat, high: Nat, lo: Word(low), hi: Word(high)) -> Word(Nat.add(low, high)):
  match low:
    case 0n: hi
    case 1n+n:
      match lo:
        case WCon{bit, rest}: WCon{bit, join(n, high, rest, hi)}

def prefix_bit(-low: Nat, -high: Nat, bit: Bool, rest: Word(low) & Word(high)) -> Word(1n+low) & Word(high):
  (lo, hi) = rest
  (WCon{bit, lo}, hi)

def split(low: Nat, high: Nat, word: Word(Nat.add(low, high))) -> Word(low) & Word(high):
  match low:
    case 0n: (WNil{}, word)
    case 1n+n:
      match word:
        case WCon{bit, rest}: prefix_bit(n, high, bit, split(n, high, rest))

law split_join:
  for +low: Nat
  for +high: Nat
  for +lo: Word(low)
  for +hi: Word(high)
  {split(low, high, join(low, high, lo, hi)) == (lo, hi) : Word(low) & Word(high)}

# Following the bits from least significant to most leaves the sign bit.
def sign(n: Nat, w: Word(1n+n)) -> Bool:
  match n:
    case 0n:
      match w:
        case WCon{bit, rest}: bit
    case 1n+p:
      match w:
        case WCon{bit, rest}: sign(p, rest)

def repeat(n: Nat, +bit: Bool) -> Word(n):
  match n:
    case 0n: WNil{}
    case 1n+p: WCon{bit, repeat(p, bit)}

def extend(+n: Nat, +extra: Nat, +w: Word(1n+n)) -> Word(Nat.add(1n+n, extra)):
  join(1n+n, extra, w, repeat(extra, sign(n, w)))

law split_extension:
  for +n: Nat
  for +extra: Nat
  for +w: Word(1n+n)
  {split(1n+n, extra, extend(n, extra, w)) ==
   (w, repeat(extra, sign(n, w))) : Word(1n+n) & Word(extra)}

def rejoin(+low: Nat, +high: Nat, fields: Word(low) & Word(high)) -> Word(Nat.add(low, high)):
  (lo, hi) = fields
  join(low, high, lo, hi)

law join_split:
  for +low: Nat
  for +high: Nat
  for +word: Word(Nat.add(low, high))
  {rejoin(low, high, split(low, high, word)) == word : Word(Nat.add(low, high))}
