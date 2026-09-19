pub type WorkloadProfile {
  WorkloadProfile(
    users: Int,
    duration_seconds: Int,
    operations_per_second: Int,
    channel_size: Int,
    server_size: Int,
    rtc_percent: Int,
    slow_consumer_percent: Int,
  )
}

pub fn default(users: Int) -> WorkloadProfile {
  WorkloadProfile(
    users: users,
    duration_seconds: 60,
    operations_per_second: max(1000, users * 4),
    channel_size: 50,
    server_size: 500,
    rtc_percent: 20,
    slow_consumer_percent: 1,
  )
}

pub fn validate(profile: WorkloadProfile) -> Result(WorkloadProfile, String) {
  case profile.users >= 10,
    profile.duration_seconds >= 1,
    profile.operations_per_second >= 1,
    profile.channel_size >= 2,
    profile.server_size >= profile.channel_size,
    between(profile.rtc_percent, 0, 100),
    between(profile.slow_consumer_percent, 0, 25)
  {
    True, True, True, True, True, True, True -> Ok(profile)
    _, _, _, _, _, _, _ -> Error("invalid Plainwire load profile")
  }
}

fn between(value: Int, low: Int, high: Int) -> Bool {
  value >= low && value <= high
}

fn max(a: Int, b: Int) -> Int {
  case a >= b {
    True -> a
    False -> b
  }
}
