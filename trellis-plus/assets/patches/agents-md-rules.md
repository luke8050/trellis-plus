## Coding Rules (trellis-plus)

1. **Think first.** State your assumptions. If a request has several readings, list them instead of silently picking one. If a simpler approach exists, say so and push back. If you cannot ask (e.g. you are a sub-agent), pick the simplest reading and note it in your report.
2. **Simplicity.** Write the least code that does what was asked. No unrequested features, options, abstractions, extra process layers, or "just in case" hooks. No defensive code for cases that cannot happen; validate only at system boundaries (user input, external calls). Don't abstract single-use code. Reuse in this order: existing code, standard library, installed dependency, minimal new code. If it could be much shorter, rewrite it.
3. **Surgical changes.** Touch only what the request requires: no drive-by refactors, formatting or comment edits. Match the existing style even if you disagree; raise concerns instead of forking conventions. Remove only the orphans (imports, variables, functions) your own change creates. Every changed line must trace to the request.
4. **Read before write.** Read callers, shared utilities and type definitions before editing. When two conventions conflict, pick one, say why, and flag the other. Don't blend them.
5. **Verify.** Turn the task into a checkable goal: bug → reproduce, fix, re-run; new validation → failing test first. Multi-step work gets a check per step.
6. **Comments explain why,** never what changed. No "as requested", no diff narration.
