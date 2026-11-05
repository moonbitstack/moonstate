# Examples

| # | Example | What it shows |
|:--:|:--|:--|
| 01 | [`strategy-graph`](01-strategy-graph/) | The strategy-graph DSL: the prebuilt `single_run`/`chat`/`react` strategies, a hand-wired start→llm→finish graph, and a `custom_node` handler over a `NodeSession`, each run against a scripted client |
| 02 | [`agent-checkpoint`](02-agent-checkpoint/) | `AgentStorage` typed key/value round-tripped through JSON (snapshot/restore) and a full `AgentCheckpoint` saved to `InMemoryPersistence`, read back latest-first |
| 03 | [`memory`](03-memory/) | `InMemoryProvider`: facts about a `MemorySubject` under a `MemoryScope` — `Concept`s, single/multiple `Fact`s, `load` by concept vs `load_all`, and bucket isolation by subject and scope |
| 04 | [`persistence`](04-persistence/) | `PersistenceStorageProvider`: save `AgentCheckpoint`s per session, list them in order or read latest-first to resume, isolated by session |
