import profile.{type WorkloadProfile}

pub type LoadPlan {
  LoadPlan(
    users: Int,
    channels: Int,
    servers: Int,
    rtc_users: Int,
    rtc_rooms: Int,
    operations_per_second: Int,
    duration_seconds: Int,
  )
}

pub fn build(workload: WorkloadProfile) -> LoadPlan {
  let rtc_users = workload.users * workload.rtc_percent / 100
  LoadPlan(
    users: workload.users,
    channels: max(1, ceil_div(workload.users, workload.channel_size)),
    servers: max(1, ceil_div(workload.users, workload.server_size)),
    rtc_users: rtc_users,
    rtc_rooms: ceil_div(rtc_users, 4),
    operations_per_second: workload.operations_per_second,
    duration_seconds: workload.duration_seconds,
  )
}

fn ceil_div(value: Int, divisor: Int) -> Int {
  case value <= 0 {
    True -> 0
    False -> (value + divisor - 1) / divisor
  }
}

fn max(a: Int, b: Int) -> Int {
  case a >= b {
    True -> a
    False -> b
  }
}
