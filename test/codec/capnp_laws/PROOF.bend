import Base
import ./LAWS.bend as Bits

def Bits.split_join(low, high, lo, hi):
  match low:
    case 0n:
      match lo:
        case WNil{}: {==}
    case 1n+n:
      match lo:
        case WCon{bit, rest}:
          %Bits.split_join(n, high, rest, hi) : {
            Bits.prefix_bit(n, high, bit, Bits.split(n, high, Bits.join(n, high, rest, hi))) ==
            Bits.prefix_bit(n, high, bit, _) : Word(1n+n) & Word(high)}
          {==}

def Bits.split_extension(n, extra, w):
  Bits.split_join(1n+n, extra, w, Bits.repeat(extra, Bits.sign(n, w)))

def rejoin_prefix(+low: Nat, +high: Nat, +bit: Bool, fields: Word(low) & Word(high)) -> {
  Bits.rejoin(1n+low, high, Bits.prefix_bit(low, high, bit, fields)) ==
  WCon{bit, Bits.rejoin(low, high, fields)} : Word(Nat.add(1n+low, high))}:
  (lo, hi) = fields
  {==}

def Bits.join_split(low, high, word):
  match low:
    case 0n: {==}
    case 1n+n:
      match word:
        case WCon{bit, tail}:
          %Bits.join_split(n, high, tail) : {
            Bits.rejoin(1n+n, high, Bits.prefix_bit(n, high, bit, Bits.split(n, high, tail))) ==
            WCon{bit, _} : Word(Nat.add(1n+n, high))}
          %rejoin_prefix(n, high, bit, Bits.split(n, high, tail)) : {
            Bits.rejoin(1n+n, high, Bits.prefix_bit(n, high, bit, Bits.split(n, high, tail))) ==
            _ : Word(Nat.add(1n+n, high))}
          {==}
