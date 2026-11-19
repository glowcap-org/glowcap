import Base

def total(sizes: List<&2, Nat>) -> Nat:
  match sizes:
    case Nil{}: 0n
    case size <> rest: Nat.add(size, total(rest))

# A chunk contributes at most the number of bytes the body still needs.
def consumed(sizes: List<&2, Nat>, +lacking: Nat) -> Nat:
  match sizes:
    case Nil{}: 0n
    case +size <> rest:
      Nat.add(Nat.min(lacking, size), consumed(rest, Nat.sub(lacking, size)))

law chunk_partitions_preserve_the_body_boundary:
  for +sizes: List<&2, Nat>
  for +lacking: Nat
  {consumed(sizes, lacking) == Nat.min(lacking, total(sizes)) : Nat}
