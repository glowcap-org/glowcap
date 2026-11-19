import Base
import ./LAWS.bend as L

def L.perspective_flip_preserves_roles(descriptor):
  match descriptor:
    case L.Near{}: {==}
    case L.Far{}: {==}
    case L.Answer{}: {==}
    case L.Other{}: {==}

def L.target_and_listener_roles_are_disjoint(perspective, descriptor):
  match perspective descriptor:
    case L.Sent{} L.Near{}: {==}
    case L.Sent{} L.Far{}: {==}
    case L.Received{} L.Near{}: {==}
    case L.Received{} L.Far{}: {==}
    case _ L.Answer{}: {==}
    case _ L.Other{}: {==}

def L.sender_targets_the_partners_export():
  {==}

def L.sender_names_its_own_export_as_listener():
  {==}

def L.unsupported_descriptors_have_no_role(perspective):
  match perspective:
    case L.Sent{}: {==}
    case L.Received{}: {==}

def L.settlement_keeps_the_question_addressable(perspective):
  match perspective:
    case L.Sent{}: {==}
    case L.Received{}: {==}

def L.only_a_live_question_is_a_wire_target(perspective):
  match perspective:
    case L.Sent{}: {==}
    case L.Received{}: {==}
