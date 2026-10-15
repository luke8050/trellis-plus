// Import the Trellis OpenCode plugin for real. `node --check` is NOT reliable (it passed a plugin that
// failed to import in enhance-wb). usage: node smoke_load.mjs <project-dir>
const dir = process.argv[2]
try {
  const mod = await import(dir + "/.opencode/plugins/inject-subagent-context.js")
  const hooks = await mod.default({ directory: dir })
  console.log("LOAD OK  hooks=" + Object.keys(hooks).join(","))
} catch (e) { console.log("LOAD FAILED:", e.constructor.name + ":", e.message.split("\n")[0]); process.exitCode = 1 }
