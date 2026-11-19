import Base
import ./LAWS.bend as L

law recover_prior:
  for +ticket: L.Stamp
  {L.prior(L.committed(ticket)) == ticket : L.Stamp}

def recover_prior(ticket):
  match ticket:
    case L.Stamp{store, incarnation, 0n, sequence}: {==}
    case L.Stamp{store, incarnation, 1n+revision, sequence}: {==}

def L.committed_stamp_identifies_ticket(a, b, mark, left, right):
  %recover_prior(a) : {_ == b : L.Stamp}
  %recover_prior(b) : {L.prior(L.committed(a)) == _ : L.Stamp}
  %Equal.sym(L.Stamp, L.committed(a), mark, left) : {
    L.prior(_) == L.prior(L.committed(b)) : L.Stamp}
  %Equal.sym(L.Stamp, L.committed(b), mark, right) : {
    L.prior(mark) == L.prior(_) : L.Stamp}
  {==}
