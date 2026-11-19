import Base

# CapTP promise settlement. Naturals stand for opaque values and errors.
type Decision is Data:
  Fulfill{value: Nat}
  Break{reason: Nat}

type Phase is Data:
  Pending{}
  Settled{decision: Decision}

def settle(phase: Phase, decision: Decision) -> Phase:
  match phase:
    case Pending{}: Settled{decision}
    case Settled{first}: Settled{first}

def apply(+attempts: List<&2, Decision>, phase: Phase) -> Phase:
  match attempts:
    case Nil{}: phase
    case next <> rest: apply(rest, settle(phase, next))

law first_settlement_wins:
  for +later: List<&2, Decision>
  for +first: Decision
  {apply(first <> later, Pending{}) == Settled{first} : Phase}

# Compare identities at one wire position. Reopening advances the stamp
# strictly. Allocations at other positions can account for any skipped stamps.
def same_stamp(+target: Nat, +live: Nat) -> Bool:
  match target live:
    case 0n 0n: True{}
    case 0n 1n+l: False{}
    case 1n+t 0n: False{}
    case 1n+t 1n+l: same_stamp(t, l)

def successor(+retired: Nat, +skipped: Nat) -> Nat:
  match retired:
    case 0n: 1n+skipped
    case 1n+older: 1n+successor(older, skipped)

law own_stamp_reads_live_row:
  for +stamp: Nat
  {same_stamp(stamp, stamp) == True{} : Bool}

law retired_stamp_cannot_read_later_row:
  for +retired: Nat
  for +skipped: Nat
  {same_stamp(retired, successor(retired, skipped)) == False{} : Bool}

# One live answer and one accepted notification now detached from the wire
# position. The notification retains its own stamp and its own settlement.
type Answers is Data:
  Answers{live: Phase, detached: Phase}

def settle_matching(live: Bool, detached: Bool, decision: Decision, answers: Answers) -> Answers:
  match live detached answers:
    case True{} _ Answers{current, prior}: Answers{settle(current, decision), prior}
    case False{} True{} Answers{current, prior}: Answers{current, settle(prior, decision)}
    case False{} False{} Answers{current, prior}: Answers{current, prior}

def settle_at(+target: Nat, live: Nat, detached: Nat, decision: Decision, answers: Answers) -> Answers:
  settle_matching(same_stamp(target, live), same_stamp(target, detached), decision, answers)

law settle_live:
  for +stamp: Nat
  for +detached: Nat
  for +decision: Decision
  for +live_phase: Phase
  for +detached_phase: Phase
  {settle_at(stamp, stamp, detached, decision, Answers{live_phase, detached_phase}) ==
   Answers{settle(live_phase, decision), detached_phase} : Answers}

law settle_detached:
  for +retired: Nat
  for +skipped: Nat
  for +decision: Decision
  for +live_phase: Phase
  for +detached_phase: Phase
  {settle_at(retired, successor(retired, skipped), retired, decision, Answers{live_phase, detached_phase}) ==
   Answers{live_phase, settle(detached_phase, decision)} : Answers}
