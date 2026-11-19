import Base
import ./LAWS.bend as L

law two_chunks:
  for +lacking: Nat
  for +first: Nat
  for +rest: Nat
  {Nat.add(Nat.min(lacking, first), Nat.min(Nat.sub(lacking, first), rest)) ==
    Nat.min(lacking, Nat.add(first, rest)) : Nat}

def two_chunks(lacking, first, rest):
  match lacking first:
    case 0n _: {==}
    case 1n+n 0n: {==}
    case 1n+n 1n+f:
      %two_chunks(n, f, rest) : {
        1n+Nat.add(Nat.min(n, f), Nat.min(Nat.sub(n, f), rest)) == 1n+_ : Nat}
      {==}

def L.chunk_partitions_preserve_the_body_boundary(sizes, lacking):
  match sizes lacking:
    case Nil{} 0n: {==}
    case Nil{} 1n+n: {==}
    case size <> rest n:
      %two_chunks(n, size, L.total(rest)) : {
        Nat.add(Nat.min(n, size), L.consumed(rest, Nat.sub(n, size))) == _ : Nat}
      %L.chunk_partitions_preserve_the_body_boundary(rest, Nat.sub(n, size)) : {
        Nat.add(Nat.min(n, size), L.consumed(rest, Nat.sub(n, size))) == Nat.add(Nat.min(n, size), _) : Nat}
      {==}
