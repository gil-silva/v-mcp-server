# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

## 5. V Rules

V-specific rules. Full reference: `../v-release-052/v/AGENTS.md`.

### Style and structure
- Doc comments use `//` (never `///` or `/**`), placed above public fns and starting with the fn
  name: `// parse does ...`.
- Generics use `[T]`, never `<T>`.
- `unsafe{}` only where required (C interop, manual memory management): smallest possible scope,
  with a comment explaining why it is needed.
- Module names must match their directory; imports follow the folder hierarchy
  (`import abc.def`). Mismatches cause silent import failures.
- No hidden or bidirectional Unicode characters in source files.
- Tools: `v fmt -w file.v` (format touched files), `v vet dir/` (style checker),
  `v doc modulename` (module docs).

### Comptime vs runtime (most common agent mistakes)
- `$if` is compile-time, not runtime: `$if windows`, `$if debug`, `$if prod`,
  `$if custom_flag ?`. Custom flags need the `?` suffix; without it the compiler silently
  ignores the condition.
- For whole-file platform code use file suffixes: `*_windows.c.v`, `*_linux.c.v`,
  `*_nix.c.v`, with `*_default.c.v` as fallback; `*_d_flag.v` is included only with
  `-d flag`. Never combine OS and flag in one suffix; use `_d_flag.v` plus `$if linux`
  inside the file.
- `$for` iterates type metadata at compile time: `StructType.fields`, `StructType.methods`,
  `EnumType.values`, `SumType.variants`; in generics use `T.fields`. V has no runtime
  reflection - a runtime `for` over struct fields does not work.
- `obj.$method()` calls are valid only inside a `$for m in Type.methods` block.
- `$`-functions: `$embed_file` (returns `EmbedFileData`; use `.to_string()`), `$tmpl`,
  `$env` (baked at compile time; use `os.getenv` for runtime values), `$d('ident', default)`,
  `$pkgconfig`, `$compile_error`, `$compile_warn`. There are no `$typeof`/`$sizeof` comptime
  calls - use `typeof(expr).name` and `sizeof(Type)`.
- Comptime type groups, usable as `$if field.typ is $int { ... }`: `$int`, `$float`,
  `$array`, `$map`, `$struct`, `$enum`, `$alias`, `$sumtype`, `$function`, `$interface`,
  `$option`.
- Compile-time pseudo variables: `@FN`, `@METHOD`, `@MOD`, `@STRUCT`, `@FILE`, `@DIR`,
  `@LINE`, `@COLUMN`, `@FILE_LINE`, `@LOCATION` (good for logging), `@VEXE`, `@VMODROOT`,
  `@BUILD_DATE`, `@BUILD_TIME`, `@BUILD_TIMESTAMP`, `@OS`, `@BACKEND`.

### Interop and Option/Result
- `C.` and `JS.` symbols belong in `.c.v` / `.js.v` files, not plain `.v` files;
  `-Wimpure-v` catches violations. Do not refactor existing interop code unless required.
- `?Type` is option (may be none), `!Type` is result (may error). Known pitfalls: unwrapping
  options in `if` guards, struct literals with option fields, option values in ternaries.

### Build, run, debug, test
- Build multi-file projects from the repo root with `v .`; never `v single_file.v` there.
- Run: `v run file.v`. Debug: `v -g run file.v` (V line numbers); C-level crashes:
  `v -keepc -cg -cc clang run file.v`.
- Generated code inspection: `-keepc` keeps the generated C, `-showcc` prints the C compile
  command, `-show-c-output` prints C compiler output, `-printfn main__main` prints only that
  generated C function (repeatable; C names look like `module__fnname`).
- Tests: `v file_test.v` (run one test file, shows output), `v -silent test dir/` (dir
  report), `v -stats test dir/` (with metrics). Filter with `VTEST_ONLY=glob`
  and `VTEST_HIDE_OK=1`.
- `VFLAGS='...'` passes flags to every V invocation.
- Output tests need exact matches (whitespace included); update expectations only when a
  behavior change was intended, else treat mismatches as regressions.

## 6. The vlang MCP server (this repo)

`bin/v-mcp-server` is the stdio MCP server this repo builds, and coding agents
running in this workspace are expected to use it instead of spawning `v`
directly. It exposes eight tools, each taking one absolute `path`:
`v_build`, `v_test`, `v_fmt_check`, `v_vet`, `v_ast`, `v_symbols`, `v_deps`,
`v_repo_brief` (the last one maps V repos via the `vrepo` library).

- OpenCode registers it globally as `vlang` in `~/.config/opencode/opencode.json`.
  Under Code Mode, call its tools from `execute`:
  `tools.vlang.v_test({ path: '/abs/path' })` — normalized tool names are
  `<server>_<tool>`.
- Always pass absolute paths; the server does no path fixing.
- Check connection state with `opencode mcp list`; reconnect with `/mcps`.
- After changing server code: rebuild with `v -o bin/v-mcp-server -no-parallel .`,
  then force clients to re-spawn the binary — in OpenCode, touch the config file
  or run `/mcps`. Connection state is long-lived: a failed spawn (e.g. racing a
  rebuild) keeps the server marked failed and its schemas cached until a
  fresh connect.
- Keep `properties.path` and `required: ["path"]` in every tool's
  `inputSchema`. Schema-validating clients silently drop arguments when a
  schema declares no properties; `v run smoke.vsh` fails if that invariant
  breaks (it counts path properties per tool and asserts the call result
  carries real data).
