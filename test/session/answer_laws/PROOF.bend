import Base
import ./LAWS.bend as L

def L.first_settlement_wins(later, first):
  match later:
    case Nil{}: {==}
    case next <> rest: L.first_settlement_wins(rest, first)

def L.own_stamp_reads_live_row(stamp):
  match stamp:
    case 0n: {==}
    case 1n+older: L.own_stamp_reads_live_row(older)

def L.retired_stamp_cannot_read_later_row(retired, skipped):
  match retired:
    case 0n: {==}
    case 1n+older: L.retired_stamp_cannot_read_later_row(older, skipped)

def L.settle_live(stamp, detached, decision, live_phase, detached_phase):
  %L.own_stamp_reads_live_row(stamp) : {
    L.settle_matching(L.same_stamp(stamp, stamp), L.same_stamp(stamp, detached), decision, L.Answers{live_phase, detached_phase}) ==
    L.settle_matching(_, L.same_stamp(stamp, detached), decision, L.Answers{live_phase, detached_phase}) : L.Answers}
  {==}

def L.settle_detached(retired, skipped, decision, live_phase, detached_phase):
  match retired:
    case 0n: {==}
    case 1n+older: L.settle_detached(older, skipped, decision, live_phase, detached_phase)
