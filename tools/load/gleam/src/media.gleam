import gleam/int

pub type MeshCost {
  MeshCost(
    participants: Int,
    peer_connections: Int,
    peers_per_client: Int,
    sharer_upload_kbps: Int,
  )
}

// This models Plainwire 2.3.0's real topology. TURN may relay a peer path, but
// it does not change the N*(N-1)/2 relationship of a full-mesh room.
pub fn mesh_cost(participants: Int, per_peer_screen_kbps: Int) -> MeshCost {
  let participants = int.clamp(participants, min: 1, max: 32)
  let peers = int.max(0, participants - 1)
  MeshCost(
    participants: participants,
    peer_connections: participants * peers / 2,
    peers_per_client: peers,
    sharer_upload_kbps: peers * int.max(0, per_peer_screen_kbps),
  )
}

pub fn client_safe_room(participants: Int, configured_limit: Int) -> Bool {
  participants <= int.clamp(configured_limit, min: 2, max: 32)
}
