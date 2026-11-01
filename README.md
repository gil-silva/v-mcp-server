# v-mcp-server

Give your coding agent real V powers: compile errors, test runs, format
checks, `v vet`, AST dumps, symbol outlines and `v.mod` inspection — through
the [Model Context Protocol] (MCP).

## What is this, in two sentences?

MCP is the protocol that lets coding agents (Claude Code, OpenCode, Zed and
friends) safely call outside tools while they work. This program is an MCP
"server": a small helper your agent starts in the background, which answers
requests like *"what errors does the compiler give for this project?"*.

Think of it as a USB port on your computer — only it plugs agents into the V
toolchain instead of a mouse.

## Why would I want it?

Without it, an agent working in your repo has to guess what "wrong" looks
like in V. With it, the agent can run `v_build` after every change and read
the real compiler output — the difference between "vibes-driven" and
"compiler-driven" AI coding.

## Requirements

- [The V language](https://vlang.io), installed and on your `PATH`.
  Check with:

  ```bash
  v version
  # tested with v 0.5.2
  ```

- A terminal. That's all — your agent starts the server itself when it
  connects; you never run it by hand if you don't want to.

## Build it once

```bash
cd v-mcp-server
v .          # builds the binary into bin/v-mcp-server
```

## Check it works (recommended)

```bash
v test .     # builds the server and talks to it like an agent would
v run smoke.vsh   # prints a full agent-style session; ends with ✓ smoke passed
```

Note: `v test .` takes under a minute (it compiles the whole project inside
the test). All green = you're ready.

## Connect your agent (once)

**Claude Code** — run this in a terminal, then restart Claude Code:

```bash
claude mcp add vlang -- /home/<you>/vlang/v-mcp-server/bin/v-mcp-server
```

**OpenCode / Zed** — open their settings JSON and register the binary as a
*stdio* MCP server:

```json
// OpenCode (opencode.json)
{
  "mcp": {
    "vlang": {
      "type": "local",
      "command": ["/home/<you>/vlang/v-mcp-server/bin/v-mcp-server"]
    }
  }
}
```

Zed's key is `context_servers`; either way, one command + zero arguments.
(Exact JSON shapes change between releases — check your client's docs if it
rejects the snippet.)

## Use it (the fun part)

Open your agent in any V project and just ask normal things:

> "Is everything formatted in src/?"
> → agent calls `v_fmt_check`

> "This build is failing and I can't tell why."
> → agent calls `v_build`, reads the diagnostics, fixes the file

> "What types and functions live in editor.v?"
> → agent calls `v_symbols`, skips reading 2,000 lines

> "Run the tests after this refactor."
> → agent calls `v_test`

## Tools reference

| Tool          | Arguments | What it does |
|---------------|-----------|--------------|
| `v_build`     | `{path}`  | compiles and returns compiler diagnostics |
| `v_test`      | `{path}`  | runs `v test` |
| `v_fmt_check` | `{path}`  | `v fmt -c` — check only, never touches files |
| `v_vet`       | `{path}`  | `v vet` warnings |
| `v_ast`       | `{path}`  | `v ast -p` AST JSON (output capped at 100 kB) |
| `v_symbols`   | `{path}`  | outline of fns/structs/interfaces/enums/consts/types + line numbers |
| `v_deps`      | `{path}`  | name/version/license/dependencies from `v.mod` |

All tools expect **absolute** paths (e.g. `/home/you/vlang/vzed`), because
the server doesn't know which folder your agent was opened in.

## Troubleshooting

- **"command not found" / agent can't connect** — check the path you
  registered; it must point to `bin/v-mcp-server`, not the project folder.
- **"no v.mod in ..." from `v_deps`** — you pointed it at a folder without
  a `v.mod`, or a *file* instead of a folder.
- **Tool outputs look truncated** — intentional cap (100 kB) so huge
  outputs don't drown the conversation; ask for a more specific file.
- **Rebuild after editing** — `v .` again; agents start the binary fresh on
  each session, your changes take effect next session (or restart the
  client).

## Notes for the curious

- Built on the official [`vlib/mcp`](https://github.com/vlang/v) module
  (protocol revision `2025-11-25` by default; stdlib handles switching).
- stdout is reserved for the protocol; all logs go to stderr.
- License: MIT (see [LICENSE](LICENSE)).

[Model Context Protocol]: https://modelcontextprotocol.io
