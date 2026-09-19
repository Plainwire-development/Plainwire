import backpressure
import capacity
import gleam/int
import gleam/io
import media
import planner
import profile
import sharding

pub fn main() {
  let workload = profile.default(1000)
  case profile.validate(workload) {
    Error(reason) -> io.println("Plainwire load-model error: " <> reason)
    Ok(valid) -> {
      let plan = planner.build(valid)
      let gateway = capacity.plan(valid.users, 25_000, 8)
      let queues = backpressure.budget(valid.users, 500, 2000, 512)
      let mesh = media.mesh_cost(8, 750)
      let shards = sharding.gateways(valid.users, 25_000, 25)
      io.println(
        "Plainwire typed load model: users="
        <> int.to_string(plan.users)
        <> " channels="
        <> int.to_string(plan.channels)
        <> " rtc_rooms="
        <> int.to_string(plan.rtc_rooms)
        <> " gateway_target="
        <> int.to_string(gateway.target_connections_per_gateway)
        <> " planned_gateways="
        <> int.to_string(shards.required_gateways)
        <> " mesh_peers="
        <> int.to_string(mesh.peer_connections)
        <> " queue_hard_bytes="
        <> int.to_string(queues.theoretical_hard_bytes),
      )
    }
  }
}
