import Base

# Only the fields used by Batch.resolve to recognize a committed batch.
type Stamp is Data:
  Stamp{store: Nat, incarnation: Nat, revision: Nat, sequence: Nat}

def committed(ticket: Stamp) -> Stamp:
  match ticket:
    case Stamp{store, incarnation, revision, sequence}:
      Stamp{store, incarnation, 1n+revision, sequence}

def prior(mark: Stamp) -> Stamp:
  match mark:
    case Stamp{store, incarnation, revision, sequence}:
      Stamp{store, incarnation, Nat.sub(revision, 1n), sequence}

law committed_stamp_identifies_ticket:
  for +a: Stamp
  for +b: Stamp
  for +mark: Stamp
  for +left: {committed(a) == mark : Stamp}
  for +right: {committed(b) == mark : Stamp}
  {a == b : Stamp}
