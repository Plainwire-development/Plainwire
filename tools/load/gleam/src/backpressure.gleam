import gleam/int

pub type QueueBudget {
  QueueBudget(
    users: Int,
    soft_messages_per_client: Int,
    hard_messages_per_client: Int,
    average_payload_bytes: Int,
    theoretical_soft_bytes: Int,
    theoretical_hard_bytes: Int,
  )
}

pub fn budget(
  users: Int,
  soft: Int,
  hard: Int,
  average_payload_bytes: Int,
) -> QueueBudget {
  let users = int.max(1, users)
  let soft = int.max(1, soft)
  let hard = int.max(soft + 1, hard)
  let bytes = int.max(1, average_payload_bytes)
  QueueBudget(
    users: users,
    soft_messages_per_client: soft,
    hard_messages_per_client: hard,
    average_payload_bytes: bytes,
    theoretical_soft_bytes: users * soft * bytes,
    theoretical_hard_bytes: users * hard * bytes,
  )
}

pub fn healthy(p95_mailbox: Int, hard_limit: Int) -> Bool {
  p95_mailbox < int.max(2, hard_limit / 2)
}
