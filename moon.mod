name = "moonbitstack/moonstate"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonstate"

license = "Apache-2.0"

keywords = [
  "state-graph",
  "graph",
  "graph-engine",
  "workflow",
  "workflow-engine",
  "state-machine",
  "superstep",
  "checkpoint",
  "checkpointing",
  "durable-execution",
  "resume",
  "interrupt",
  "human-in-the-loop",
  "time-travel",
  "fan-out",
  "send",
  "subgraph",
  "executor",
  "pregel",
  "langgraph",
  "agent",
  "orchestration",
  "json",
  "sql-checkpoint",
  "checkpoint-saver",
  "sqlite",
  "postgres",
  "postgresql",
  "mysql",
  "mariadb",
  "database",
  "durable-workflow",
  "moonbit",
]

description = "Durable state graphs for MoonBit: nodes, merging, checkpoints, interrupts and resume. No model in sight."

source = "src"

import {
  "moonbitlang/async@0.22.5",
  "moonbitstack/moondb@0.2.7",
  "moonbitstack/moontel@0.1.1",
}
