# v-mcp-server

MCP ([Model Context Protocol]) server that hands coding agents real V
tooling: build diagnostics, test runs, format checks, vet, AST JSON,
symbol outlines and `v.mod` inspection — over stdio.

## Install / run

```bash
v .           # builds bin/v-mcp-server
v test .      # self-driving integration test (client + server in one process tree)
```

## Register with an agent

Claude Code: `claude mcp add vlang -- /home/racoon/vlang/v-mcp-server/bin/v-mcp-server`
Zed / OpenCode: point a stdio MCP server entry at the same binary.

## Tools

| Tool           | Arguments     | Behavior |
|----------------|---------------|----------|
| `v_build`      | `{path}`      | `v -o tmp -no-parallel path` — compiler diagnostics |
| `v_test`       | `{path}`      | `v test path` |
| `v_fmt_check`  | `{path}`      | `v fmt -c path` (check-only; exit 1 if unformatted) |
| `v_vet`        | `{path}`      | `v vet path` |
| `v_ast`        | `{path}`      | `v ast -p path` — AST JSON on stdout |
| `v_symbols`    | `{path}`      | pure-V outline: fn/struct/interface/enum/const/type + line numbers |
| `v_deps`       | `{path}`      | name/version/license/dependencies from `path/v.mod` |

All tools take ABSOLUTE paths. Outputs are capped (100 kB) with a
truncation marker; long tool calls are the point, secrets are not.

## Design notes

- Built on the official `vlib/mcp` module (`2025-11-25` revision by
  default; per-request switching is inherited from the stdlib).
- stdout is protocol; every log goes to stderr.
- v.mod `license: MIT`; see LICENSE.

[Model Context Protocol]: https://modelcontextprotocol.io
