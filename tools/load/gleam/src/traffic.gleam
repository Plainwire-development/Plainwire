pub type TrafficClass {
  ChannelMessage
  DirectMessage
  Typing
  Presence
  RtcSignal
}

// The runtime harness mirrors this deterministic mix. Keeping the policy typed
// makes workload changes reviewable instead of hiding them in random branches.
pub fn class_for(sequence: Int) -> TrafficClass {
  case sequence % 20 {
    0 -> DirectMessage
    1 -> Typing
    2 -> Presence
    3 -> RtcSignal
    _ -> ChannelMessage
  }
}

pub fn durable(class: TrafficClass) -> Bool {
  case class {
    ChannelMessage | DirectMessage -> True
    Typing | Presence | RtcSignal -> False
  }
}
