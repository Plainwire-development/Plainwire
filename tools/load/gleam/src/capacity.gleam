import gleam/int

pub type GatewayCapacity {
  GatewayCapacity(
    users: Int,
    target_connections_per_gateway: Int,
    headroom_percent: Int,
    gateways: Int,
    connection_supervisors: Int,
    connections_per_supervisor: Int,
    suggested_file_descriptors: Int,
  )
}

pub fn plan(
  users: Int,
  target_connections_per_gateway: Int,
  supervisors: Int,
) -> GatewayCapacity {
  let safe_users = int.max(1, users)
  let target = int.max(1000, target_connections_per_gateway)
  let headroom_users = ceil_div(safe_users * 125, 100)
  let gateways = int.max(1, ceil_div(headroom_users, target))
  let supervisors = int.clamp(supervisors, min: 1, max: 64)
  let per_gateway = ceil_div(headroom_users, gateways)
  GatewayCapacity(
    users: safe_users,
    target_connections_per_gateway: target,
    headroom_percent: 25,
    gateways: gateways,
    connection_supervisors: supervisors,
    connections_per_supervisor: ceil_div(per_gateway, supervisors),
    suggested_file_descriptors: per_gateway + 4096,
  )
}

fn ceil_div(value: Int, divisor: Int) -> Int {
  case value <= 0 {
    True -> 0
    False -> {
      let numerator = value + divisor - 1
      numerator / divisor
    }
  }
}
