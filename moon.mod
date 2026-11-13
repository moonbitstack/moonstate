name = "moonbitstack/moonstate"

version = "0.1.1"

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
  "checkpoint-conformance",
  "conformance",
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
  "opentelemetry",
  "otel",
  "otel-tracing",
  "tracing",
  "observability",
  "moonbit",
]

description = "Durable state graphs for MoonBit: nodes, merging, checkpoints, interrupts and resume. No model in sight."

source = "src"

import {
  "moonbitlang/async@0.22.5",
  "moonbitstack/moonjson@0.5.0",
  "moonbitstack/moondb@0.3.0",
  "moonbitstack/moontel@0.2.0",
}
