import gleam/int

pub type ShardPlan {
  ShardPlan(
    users: Int,
    target_users_per_gateway: Int,
    headroom_percent: Int,
    required_gateways: Int,
  )
}

// Planning model only. Plainwire 2.2.0 intentionally keeps one realtime owner;
// this prevents capacity planning from being hidden in ad-hoc shell arithmetic
// while the transport/routing boundary evolves independently.
pub fn gateways(users: Int, target_users_per_gateway: Int, headroom_percent: Int) -> ShardPlan {
  let users = int.max(1, users)
  let target = int.max(1000, target_users_per_gateway)
  let headroom = int.clamp(headroom_percent, min: 0, max: 100)
  let planned_users = ceil_div(users * (100 + headroom), 100)
  ShardPlan(
    users: users,
    target_users_per_gateway: target,
    headroom_percent: headroom,
    required_gateways: int.max(1, ceil_div(planned_users, target)),
  )
}

fn ceil_div(value: Int, divisor: Int) -> Int {
  case value <= 0 {
    True -> 0
    False -> (value + divisor - 1) / divisor
  }
}
