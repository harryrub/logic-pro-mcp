# Logic Pro MCP — install state (2026-04-17, resumed)

## Where things are

- **Repo:** `~/Code/logic-pro-mcp`
- **Fork:** [github.com/harryrub/logic-pro-mcp](https://github.com/harryrub/logic-pro-mcp) (upstream: koltyj/logic-pro-mcp)
- **Built binary:** `~/Code/logic-pro-mcp/.build/release/LogicProMCP`
- **Registered with Claude Code:** user scope, name `logic-pro` (in `~/.claude.json`)
- **Branch:** `fix/swift6-clt-compat` — contains 1 commit lowering Package.swift tools-version from 6.0 → 5.9. **This fix did NOT resolve the CLT build issue** (the real fix was installing swiftly). The commit is kept as a documented experiment.

## Build toolchain

- Cannot build with Command Line Tools' Swift — known PackageDescription ABI mismatch.
- Working Swift: `~/.swiftly/bin/swift` (Swift 6.3.1, installed via `brew install swiftly` + `swiftly init --assume-yes`).
- Re-enter build env with: `export PATH="$HOME/.swiftly/bin:$PATH"` then `swift build -c release`.

## Permission state

- ✅ Accessibility: GRANTED
- ✅ Automation (Logic Pro): GRANTED

Install verified end-to-end on 2026-04-17: `logic_transport goto_position bar 1` executed successfully against a running Logic Pro instance.

## Useful one-liners

```bash
# Verify permissions
~/Code/logic-pro-mcp/.build/release/LogicProMCP --check-permissions

# Rebuild after pulling upstream
cd ~/Code/logic-pro-mcp && export PATH="$HOME/.swiftly/bin:$PATH" && swift build -c release

# Pull upstream updates from koltyj
cd ~/Code/logic-pro-mcp && git fetch upstream && git checkout main && git merge upstream/main

# See registered MCP servers
claude mcp list
```

## Known gaps worth filing as issues with koltyj

- Swift 6 CLT build failure — undocumented; could add a README section recommending swiftly or Xcode.
- Deprecation warnings in TransportDispatcher.swift and LogicProServer.swift for `.text(_:metadata:)` — the MCP SDK has moved to `.text(text:annotations:_meta:)`.

## Research context (why we did this)

Harry wants to use Claude to control Logic Pro for music production workflows. Audited 5 YouTube videos + manual for SnappySnap ($55 plugin-hosting MCP). Koltyj's server is the free alternative for session/transport/track control — it does NOT adjust plugin knobs (that's MongLong0214's fork or SnappySnap's territory).
