# Plainwire typed load model

This Gleam package is the type-safe reference model for Plainwire's synthetic load scenarios. It defines validated workload profiles, deterministic traffic classes, topology planning, and pass/fail objectives. The executable Erlang harness remains `../pw_load_sim.erl` so `make load` has no extra production runtime dependency.

Run `make load-gleam-check` when Gleam is installed. The main application does not depend on Gleam at runtime.
