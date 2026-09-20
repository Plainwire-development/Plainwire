import gleam/list

pub type LoadResult {
  LoadResult(
    operations: Int,
    p95_mailbox: Int,
    p99_mailbox: Int,
    max_mailbox: Int,
    hard_mailbox_limit: Int,
    live_clients: Int,
    requested_users: Int,
  )
}

pub type Verdict {
  Pass
  Fail(List(String))
}

pub fn evaluate(result: LoadResult) -> Verdict {
  let failures = []
  let failures = case result.operations > 0 {
    True -> failures
    False -> ["no operations executed", ..failures]
  }
  let failures = case result.max_mailbox < result.hard_mailbox_limit {
    True -> failures
    False -> ["a live client mailbox reached the hard limit", ..failures]
  }
  let failures = case
    result.live_clients > 0 && result.live_clients <= result.requested_users
  {
    True -> failures
    False -> ["client accounting is inconsistent", ..failures]
  }
  case failures {
    [] -> Pass
    _ -> Fail(list.reverse(failures))
  }
}
