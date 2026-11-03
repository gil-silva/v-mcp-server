// v-mcp-server
// An MCP (Model Context Protocol) server that exposes V development tooling
// to coding agents: program compilation and execution, standalone-snippet
// runs (v_scratch), structured build errors, test runs, formatting checks
// (verify and in-place fix), vet warnings, AST dumps, symbol outlines,
// one-symbol source slices (v_read), module docs (v_doc), repo briefs,
// v.mod inspection and a v.mod project lookup (v_where), affected-test
// selection, who-uses-what queries (definitions, callers, interface
// implementations) and a server build/info report.
//
// Built on the official `mcp` module of the V standard library; serves
// over stdio (newline-delimited JSON-RPC), the transport used by Claude
// Code, OpenCode, Zed and friends.
module main

import mcp
import json2
import os
import time
import crypto.sha256
import gil_silva.vrepo.vrepo
import gil_silva.vaffected.vaffected
import gil_silva.vuses.vuses

const server_name = 'v-mcp-server'

const server_version = '0.8.0'

// output_byte_limit caps any tool output, so agents never choke on
// multi-megabyte AST dumps or test logs.
const output_byte_limit = 100_000

// path_args_schema is the shared inputSchema of the tools that take only a
// path. Clients validate tool arguments against this schema, so declaring
// `properties` (and `required`) is what lets the `path` argument through;
// the bare default schema makes clients drop all arguments.
const path_args_schema = '{"type":"object","properties":{"path":{"description":"Absolute path of a V file or project directory","type":"string"}},"required":["path"],"additionalProperties":false}'

// v_affected_schema declares path as required and base as optional; without
// base the tool diffs against HEAD.
const v_affected_schema = '{"type":"object","properties":{"path":{"description":"Absolute path of a V project directory","type":"string"},"base":{"description":"Git rev to diff against (default: HEAD)","type":"string"}},"required":["path"],"additionalProperties":false}'

// v_run_schema declares path as required, args as optional argv, stdin as
// an optional string for the program's stdin, timeout as an optional
// per-call seconds cap and vflags as optional compiler flags; without args
// the program runs with none, without stdin it has no input. `path` must
// stay the first property — smoke.vsh counts `"properties":{"path":{`
// occurrences server-wide.
const v_run_schema = '{"type":"object","properties":{"path":{"description":"Absolute path of a V file or project directory","type":"string"},"args":{"description":"Positional arguments passed to the compiled program (optional, JSON array of strings)","type":"array","items":{"type":"string"}},"stdin":{"description":"Text piped to the program as stdin, verbatim and closed with EOF afterwards (optional string; no trailing newline is added. Interactive programs and readers expecting EOF need this.)","type":"string"},"timeout":{"description":"Per-call timeout cap in seconds, 1..1800 (optional integer, default 600): the compile step and the program run are each killed when they exceed it","type":"integer"},"vflags":{"description":"Extra flags passed verbatim to the v CLI (optional, JSON array of strings, e.g. [\\"-prod\\"] or [\\"-cc\\",\\"clang\\"])","type":"array","items":{"type":"string"}}},"required":["path"],"additionalProperties":false}'

// v_scratch_schema backs the projectless v_scratch tool: code is required
// (the complete standalone program source — a program with fn main or plain
// top-level statements, which V compiles in script mode) and stdin/vflags
// are optional. There is no path — smoke.vsh counts this tool's concepts
// separately, so `code` must stay the first property
// (`"properties":{"code":{`).
const v_scratch_schema = '{"type":"object","properties":{"code":{"description":"Complete standalone V source: either a program with fn main, or plain top-level statements (compiled in V script mode). Nothing is wrapped","type":"string"},"stdin":{"description":"Text piped to the program as stdin, verbatim and closed with EOF afterwards (optional string; no trailing newline is added)","type":"string"},"vflags":{"description":"Extra flags passed verbatim to the v CLI (optional, JSON array of strings, e.g. [\\"-g\\"] or [\\"-cc\\",\\"clang\\"])","type":"array","items":{"type":"string"}}},"required":["code"],"additionalProperties":false}'

// v_build_schema declares path as required and vflags as an optional list of
// CLI flags forwarded verbatim to the v compiler (e.g. -g, -prod, -cc clang).
// `path` must stay the first property — smoke.vsh counts
// `"properties":{"path":{` occurrences server-wide.
const v_build_schema = '{"type":"object","properties":{"path":{"description":"Absolute path of a V file or project directory","type":"string"},"vflags":{"description":"Extra flags passed verbatim to the v CLI (optional, JSON array of strings, e.g. [\\"-prod\\"] or [\\"-cc\\",\\"clang\\"])","type":"array","items":{"type":"string"}}},"required":["path"],"additionalProperties":false}'

// v_errors_schema mirrors v_build_schema and adds the optional per-call
// `timeout` cap for the compile step plus `limit`, a row cap on the JSON
// reply; v_build (same payload shape, no override accepted) keeps declaring
// only path/vflags.
const v_errors_schema = '{"type":"object","properties":{"path":{"description":"Absolute path of a V file or project directory","type":"string"},"vflags":{"description":"Extra flags passed verbatim to the v CLI (optional, JSON array of strings, e.g. [\\"-prod\\"] or [\\"-cc\\",\\"clang\\"])","type":"array","items":{"type":"string"}},"timeout":{"description":"Per-call timeout cap in seconds, 1..1800 (optional integer, default 600): the compile step is killed when it exceeds it","type":"integer"},"limit":{"description":"Cap the diagnostics at the first N rows (optional integer, ≥ 1). When longer lists exist the reply is an object {rows,total,truncated:true} instead of the plain row array","type":"integer"}},"required":["path"],"additionalProperties":false}'

// server_info_schema backs the no-argument v_server_info tool. It is the one
// tool that intentionally declares nothing; smoke.vsh excludes it when
// enforcing the properties invariant of every other tool.
const server_info_schema = '{"type":"object","properties":{},"additionalProperties":false}'

// v_test_schema declares path as required, only as an optional glob that
// selects test functions, files as an optional VTEST_ONLY filter that
// selects test files (both forwarded through env(1)), stats as an
// optional boolean switching to structured per-test rows (failing rows
// additionally carry at/detail), and timeout as the optional per-call cap
// for the whole test run; `path` must stay
// the first property — smoke.vsh counts `"properties":{"path":{`
// occurrences server-wide.
const v_test_schema = '{"type":"object","properties":{"path":{"description":"Absolute path of a V test file or project directory","type":"string"},"only":{"description":"VTEST_ONLY_FN glob: run only test functions whose name matches (optional string, e.g. \\"*handshake*\\")","type":"string"},"files":{"description":"VTEST_ONLY filter: run only the test files whose path (relative to path) contains one of the comma-separated patterns (optional string, e.g. \\"parse_test.v\\"); pairs with the v_affected output","type":"string"},"stats":{"description":"Return structured per-test rows [{file,name,ok,ms,asserts}] instead of raw output (optional boolean); failing rows also carry at (the file:LINE: fn name header v prints above the row) and detail (the failing statement plus its captured values); the raw output trails the rows as failure detail when tests fail; a failed run (failing tests, timeout, or a mid-run death) is an error result","type":"boolean"},"timeout":{"description":"Per-call timeout cap in seconds, 1..1800 (optional integer, default 600): the whole test run is killed when it exceeds it","type":"integer"}},"required":["path"],"additionalProperties":false}'

// v_uses_schema declares path as required and symbol as an optional string
// the tool itself validates; same `path`-first rule as every other schema.
const v_uses_schema = '{"type":"object","properties":{"path":{"description":"Absolute path of a V project directory to scan","type":"string"},"symbol":{"description":"The declared V symbol name to query (fn/method/struct/interface/enum/const/type name)","type":"string"}},"required":["path"],"additionalProperties":false}'

// v_read_schema declares the .v file (path) as required; symbol is validated
// by the tool itself; same `path`-first rule as every other schema.
const v_read_schema = '{"type":"object","properties":{"path":{"description":"Absolute path of a single .v source file","type":"string"},"symbol":{"description":"The declared symbol to return verbatim (fn/method/struct/interface/enum/const/type name, e.g. run_capture)","type":"string"}},"required":["path"],"additionalProperties":false}'

// v_where_schema declares path as the directory to scan for v.mod projects.
// `path` must stay the first property — smoke.vsh counts
// `"properties":{"path":{` occurrences server-wide.
const v_where_schema = '{"type":"object","properties":{"path":{"description":"Absolute directory to scan for V projects (folders containing a v.mod); scanned a few levels deep","type":"string"}},"required":["path"],"additionalProperties":false}'

// fmt_check_schema backs v_fmt_check alone (the other path-only tools share
// path_args_schema): the optional `diff` switch returns what `v fmt` would
// change alongside the file list. Same `path`-first rule.
const fmt_check_schema = '{"type":"object","properties":{"path":{"description":"Absolute path of a single .v source file or a directory","type":"string"},"diff":{"description":"Also return the unified diff of what v fmt would change (optional boolean): the reply carries the unformatted file list and the diff, and stays an error result while drift exists","type":"boolean"}},"required":["path"],"additionalProperties":false}'

// PathArgs is the common `arguments` payload of the tools below:
// a path to a single .v file or a project directory.
struct PathArgs {
	path string
}

// FmtCheckArgs is the payload of v_fmt_check: a path to verify formatting
// on, plus the optional diff switch that returns what `v fmt` would change.
struct FmtCheckArgs {
	path string
	diff ?bool
}

// v_gate_schema backs the one-call commit gate — path required; base (the
// git rev the affected set diffs against) and run_tests (execute the
// narrowed suite) optional. Same `path`-first rule.
const v_gate_schema = '{"type":"object","properties":{"path":{"description":"Absolute path of a V project directory (a git repository, since the affected-set step runs git diff)","type":"string"},"base":{"description":"Git rev to diff against for the affected test subset (optional string, default HEAD)","type":"string"},"run_tests":{"description":"Execute the affected test files in the same call (optional boolean): the report gains parsed test rows among the sections, and any executed test failure fails the whole gate","type":"boolean"}},"required":["path"],"additionalProperties":false}'

// GateArgs is the payload of v_gate: the project path, the optional git base
// the affected-set diff runs against (default HEAD), and the optional
// run_tests switch that executes the affected suite in the same call.
struct GateArgs {
	path      string
	base      ?string
	run_tests ?bool
}

// TestArgs is the payload of v_test: a path, an optional VTEST_ONLY_FN glob
// (test function names), an optional VTEST_ONLY filter (test file paths),
// an optional switch to the structured (-stats) report, and an optional
// per-call timeout cap.
struct TestArgs {
	path    string
	only    ?string
	files   ?string
	stats   ?bool
	timeout ?int
}

// BuildArgs is the payload of v_build and v_errors: a path plus optional CLI
// flags forwarded verbatim to the v compiler, and (v_errors only) an
// optional per-call timeout cap for the compile step and cap (limit) on the
// count of JSON diagnostic rows.
struct BuildArgs {
	path    string
	vflags  ?[]string
	timeout ?int
	limit   ?int
}

// RunArgs is the payload of v_run: path plus optional positional arguments
// (argv) forwarded to the compiled program, optional stdin fed to it
// verbatim, optional compiler flags for the build step, and an optional
// per-call timeout cap.
struct RunArgs {
	path    string
	args    ?[]string
	stdin   ?string
	vflags  ?[]string
	timeout ?int
}

// ScratchArgs is the payload of v_scratch: the complete standalone program
// source, optional stdin for it, and optional compiler flags. Everything
// that usually comes through a file path instead rides in the payload —
// the projectless tool has no path.
struct ScratchArgs {
	code   string
	stdin  ?string
	vflags ?[]string
}

// One compiler diagnostic, as emitted by `v` on the header line
// `file.v:LINE:COL: kind: message`.
struct Diagnostic {
pub:
	file    string
	line    int
	col     int
	kind    string
	message string
}

// TruncatedDiags is the over-limit v_errors reply: the first rows
// diagnostics plus the real total, so the agent sees both the cap and the
// full count in one reply.
struct TruncatedDiags {
pub:
	rows      []Diagnostic
	total     int
	truncated bool
}

// AffectedArgs is the payload of v_affected: path plus the optional git rev
// to diff against ('HEAD' when absent).
struct AffectedArgs {
	path string
	base ?string
}

// UsesArgs is the payload of v_uses: the project (path) to scan and the
// declared symbol name to query. An empty symbol is a tool-level error.
struct UsesArgs {
	path   string
	symbol string
}

// ReadArgs is the payload of v_read: a single .v file (path) plus the
// declared symbol name to return verbatim. An empty symbol is a tool error.
struct ReadArgs {
	path   string
	symbol string
}

// decode_args parses a tool `arguments` JSON into T.
fn decode_args[T](arguments string) !T {
	return json2.decode[T](arguments, json2.DecoderOptions{})!
}

// validate_path rejects the two most common agent mistakes up front — a
// relative path (the server does no path fixing and the agent's CWD isn't
// ours) and a path that does not exist — instead of letting `v` produce a
// cryptic stream about missing files. Every tool calls this right after
// decoding its arguments.
fn validate_path(path string) ! {
	if !os.is_abs_path(path) {
		return error('path must be ABSOLUTE (got "${path}"): the server does not fix relative paths')
	}
	if !os.exists(path) {
		return error('path does not exist: ${path}')
	}
}

// filter_allowed_chars lists the characters a VTEST_ONLY (test files) or
// VTEST_ONLY_FN (test functions) filter may contain: word characters plus
// the command's separators — glob metacharacters * ? [] and - for fn names,
// / for file paths and , to list several patterns. Spaces and quotes stay
// out by design — the string travels verbatim through env(1) as VAR=value
// text.
const filter_allowed_chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.*?[]-/,'

// validate_filter rejects a test-function glob or a test-file filter that
// carries characters no filter needs, before it ever reaches env(1).
fn validate_filter(pattern string) ! {
	allowed := filter_allowed_chars.bytes()
	for b in pattern.bytes() {
		if b !in allowed {
			return error('unsupported character "${b.ascii_str()}": fn globs (only) and file filters (files) allow word characters plus * ? [ ] -, and file filters may also use / and ,')
		}
	}
}

// validate_vflags checks the argv shape of forwarded compiler flags: every
// element starts with '-' (an option) or is the single value right after an
// option (`-cc clang`). A non-dash element in any other slot — usually a
// source path that belongs in `path` — is rejected with a clear message
// instead of quietly compiling the wrong files.
fn validate_vflags(flags []string) ! {
	mut prev_was_flag := false
	for i, flag in flags {
		if flag.len == 0 {
			return error('vflags[${i}] is an empty string')
		}
		if flag.starts_with('-') {
			prev_was_flag = true
		} else {
			if !prev_was_flag {
				return error('vflags[${i}] ("${flag}") does not start with "-": pass sources through "path" and options as flags (e.g. ["-cc","clang"])')
			}
			prev_was_flag = false
		}
	}
}

// tool_timeout_seconds caps any spawned `v` subcommand. The server processes
// tool calls sequentially, so one wedged child (a hung test runner, an
// interactive prompt) must not silently queue every other call behind it.
const tool_timeout_seconds = 600

// tool_timeout_seconds_max bounds a call's `timeout` override (v_run, v_test,
// v_errors): a test suite or a big compile can legitimately need well past
// the default, but an agent asking for hours of hang time is misusing it —
// 30 minutes covers any real run.
const tool_timeout_seconds_max = 1800

// resolve_timeout folds an optional per-call `timeout` override into an
// absolute seconds value: no argument means the server default
// (tool_timeout_seconds); an argument must land in 1..tool_timeout_seconds_max
// or the call is refused before anything spawns.
fn resolve_timeout(seconds ?int) !int {
	asked := seconds or { return tool_timeout_seconds }
	if asked < 1 || asked > tool_timeout_seconds_max {
		return error('timeout: ${asked} s must be between 1 and ${tool_timeout_seconds_max} (default ${tool_timeout_seconds})')
	}
	return asked
}

// Capture is everything run_capture learned about one child process: the
// two output streams, unmerged (callers decide how to display them), the
// exit code, and whether the tool timeout fired.
struct Capture {
	stdout    string
	stderr    string
	exit_code int
	timed_out bool
}

// run_capture spawns args[0] with args[1..] and polls it to completion:
// no timed wait exists in v 0.5.2 (os.Process), so the child is checked
// every 500 ms until the seconds cap (SIGTERM first, then SIGKILL
// after 3 s) — the server default via tool_timeout_seconds, or a call's
// timeout= override handed down through the tool fns. Shared by every
// spawning caller — run_v_tool, the compile step behind the cache, the
// built-program runners (v_run, v_scratch), v_test's stats branch,
// v_affected's git probe, v_server_info and the toolchain stamp — each
// formats the Capture its own way.
fn run_capture(args []string, seconds int) Capture {
	return capture_sh_line('exec "$@" < /dev/null', args, seconds)
}

// compile_capture is run_capture for compile invocations: it exports a
// fresh V3CACHE root to each compile so the driver always builds cold. The
// current toolchain mishandles a resumed prepared-module preamble on
// directory-target rebuilds (a second identical compile reports a duplicate
// seeded closure-runtime import and cascades bogus cached-header errors), so
// replays must not resume: a cold build is the one reliable compile route.
fn compile_capture(args []string, seconds int) Capture {
	return capture_sh_line('V3CACHE=${compile_v3cache_root()}; export V3CACHE; exec "$@" < /dev/null',
		args, seconds)
}

// capture_sh_line is the sh(1) runner under which every spawn here executes:
// `exec` keeps every argument byte-verbatim (nothing user-supplied is parsed
// by the shell), and `< /dev/null` gives the child an empty stdin instead of
// redirect-stdio's never-written, never-closed pipe — on which children that
// read stdin (vfmt on an input dir with no .v files, a v_run program reading
// its stdin with none piped) block until the timeout cap kills them.
fn capture_sh_line(line string, args []string, seconds int) Capture {
	mut cmd := []string{cap: args.len + 4}
	cmd << 'sh'
	cmd << '-c'
	cmd << line
	cmd << 'v-mcp-server-capture'
	cmd << args
	mut p := os.new_process(cmd[0])
	p.set_args(cmd[1..])
	p.set_redirect_stdio()
	p.run()
	defer {
		p.close()
	}
	start := time.now().unix()
	mut timed_out := false
	for p.is_alive() {
		if time.now().unix() - start > i64(seconds) {
			if !timed_out {
				timed_out = true
				p.signal_term()
				time.sleep(3 * time.second)
				if p.is_alive() {
					p.signal_kill()
				}
			}
		}
		time.sleep(500 * time.millisecond)
	}
	p.wait() // reaps the (exited) child and sets p.code
	return Capture{
		stdout:    p.stdout_slurp()
		stderr:    p.stderr_slurp()
		exit_code: p.code
		timed_out: timed_out
	}
}

// merge_streams joins captured stdout/stderr the way run_v_tool displays them.
fn merge_streams(stdout string, stderr string) string {
	mut out := stdout
	if stderr != '' {
		// a separation newline only when stdout is non-empty
		out += (if out != '' { '\n' } else { '' }) + stderr
	}
	return out.trim_space()
}

// run_v_tool executes a `v` subcommand (seconds = this call's cap, the
// server default via tool_timeout_seconds) and wraps its output in an MCP
// tool result. A non-zero exit code yields an error result carrying both
// streams.
fn run_v_tool(args []string, seconds int) mcp.ToolResult {
	c := run_capture(args, seconds)
	mut out := merge_streams(c.stdout, c.stderr)
	if c.exit_code != 0 || c.timed_out {
		if out.len == 0 {
			if c.timed_out {
				out = 'command timed out after ${seconds} s'
			} else {
				out = 'command failed with exit code ${c.exit_code}'
			}
		}
		return to_error_result(out)
	}
	if out == '' {
		out = 'ok (exit 0, no output)'
	}
	return mcp.tool_text_result(truncate(out))
}

fn to_error_result(text string) mcp.ToolResult {
	// ToolResult.is_error is immutable outside mcp; assign at construction.
	// (Follow-up: upstream `tool_error_result` should be `pub fn`.)
	return mcp.ToolResult{
		content:  mcp.tool_text_result(truncate(text)).content
		is_error: true
	}
}

// truncate caps long tool outputs; agents chunk better than they download.
// The cut backs off to a UTF-8 boundary so the tail never starts mid-rune.
fn truncate(text string) string {
	if text.len <= output_byte_limit {
		return text
	}
	mut cut := output_byte_limit
	for cut > 0 && (text[cut] & 0xC0) == 0x80 {
		cut--
	}
	return text[..cut] + '\n... [truncated; ${text.len} bytes total]'
}

// tmp_output_path returns a unique absolute path for a temp build output.
fn tmp_output_path(tag string) string {
	return os.join_path(os.temp_dir(),
		'mcp_vlang_${tag}_${os.getpid()}_${time.now().unix().str()}_random_1')
}

// compile_v3cache_root creates a fresh per-compile V3CACHE root under the
// system temp dir, so every compile rebuilds cold; roots older than an hour
// (their run_ stamp carries the unix second) are dropped opportunistically.
fn compile_v3cache_root() string {
	base := os.join_path(os.temp_dir(), 'mcp_vlang_v3cache')
	os.mkdir_all(base) or {}
	for entry in os.ls(base) or { []string{} } {
		stamp := entry.all_after('run_').all_before('_')
		mut all_digits := stamp.len > 0
		for i in 0 .. stamp.len {
			c := stamp[i]
			if c < 48 || c > 57 {
				all_digits = false
				break
			}
		}
		if all_digits {
			born := stamp.int()
			if born > 0 && time.now().unix() - born > 3600 {
				os.rmdir_all(os.join_path(base, entry)) or {}
			}
		}
	}
	root := os.join_path(base, 'run_${time.now().unix()}_${os.getpid()}_${time.sys_mono_now()}')
	os.mkdir_all(root) or {}
	return root
}

// compile_args assembles the v compile invocation shared by v_build, v_run
// and v_errors: optional vflags first, then the temp output and the target.
fn compile_args(bin string, path string, flags []string) []string {
	// 'v' + flags + '-o' + bin + '-no-parallel' + path
	mut cargs := []string{cap: 5 + flags.len}
	cargs << 'v'
	cargs << flags
	cargs << '-o'
	cargs << bin
	cargs << '-no-parallel'
	cargs << path
	return cargs
}

// ---- warm build cache -------------------------------------------------------
//
// The agent edit loop compiles the same tree over and over (v_errors,
// v_build, v_run chain on identical sources). Each cache entry stores the
// raw facts of one compile — merged streams, success flag, a fallback
// summary for silent failures — in result.json, and the freshly linked
// binary beside it at bin/ when the compile succeeded. Entries are keyed by
// a hash of the toolchain stamp, the request (real path + vflags) and
// content hashes of every .v source in scope, so a hit means bytes-for-bytes
// the same inputs, not just "mtime looks the same".

// Cache bounds: how many entries pruning keeps, how old an entry may get
// before pruning drops it, and how much of the merged compile output is
// stored with a record (what an agent sees is still capped by truncate()).
const cache_keep_entries = 16
const cache_max_age_hours = 24 * 14
const cache_max_stored_bytes = 400_000

// CachedBuild is the compile record stored in an entry's result.json (with
// the executable beside it at bin/) — the raw facts of one build: merged
// streams, success flag and a fallback summary for silent failures.
struct CachedBuild {
pub:
	ok      bool
	text    string
	summary string
}

// BuildOutcome is the shared compile step result: the record (from the cache
// on a hit) plus the executable path to run, empty when none exists.
struct BuildOutcome {
pub:
	ok       bool
	text     string
	summary  string
	hit      bool
	bin_path string
}

// cache_dir returns the machine-local cache root, created on demand.
fn cache_dir() string {
	dir := os.join_path(os.temp_dir(), 'mcp_vlang_cache')
	os.mkdir(dir) or {} // exists is the normal case
	return dir
}

// refresh_toolchain_stamp records `v -version` in the cache dir. Cache keys
// fold this stamp in, so upgrading the toolchain invalidates stale entries;
// one cheap spawn per server start.
fn refresh_toolchain_stamp() {
	c := run_capture(['v', '-version'], tool_timeout_seconds)
	if c.timed_out || c.exit_code != 0 {
		return
	}
	os.write_file(os.join_path(cache_dir(), 'toolchain.txt'), c.stdout.trim_space()) or {}
}

// toolchain_stamp reads the recorded version (an empty string when the
// startup probe never wrote it).
fn toolchain_stamp() string {
	return os.read_file(os.join_path(cache_dir(), 'toolchain.txt')) or { '' }
}

// build_cache_key hashes the full build identity: toolchain stamp, realpath
// and vflags of the request, plus content hashes of the .v sources in scope
// (the whole tree under a directory target; a plain file target by itself;
// a *_test.v target together with the .v siblings of its directory, which V
// pulls into the compile beside the test) and the v.mod beside them (it
// names the dependencies). Content hashes, not
// mtimes, decide hits: a touched-but-unchanged tree can hit, a rewritten
// same-size file cannot. Unreadable pieces are skipped rather than invented;
// an empty key — unreadable target, or a path that is neither a .v file nor
// a directory — means the caller compiles without the cache.
fn build_cache_key(path string, flags []string) string {
	mut manifest := []string{}
	manifest << 'toolchain:\x1f${toolchain_stamp()}'
	manifest << 'path:\x1f${os.real_path(path)}'
	if flags.len > 0 {
		manifest << 'vflags:\x1f${flags.join('\x1f')}'
	}
	if os.is_dir(path) {
		collect_source_rows(path, '', mut manifest)
	} else if path.ends_with('.v') {
		src := os.read_file(path) or { return '' }
		manifest << '${os.file_name(path)}\x1f${sha256.sum(src.bytes()).hex()[..16]}'
		if os.file_name(path).ends_with('_test.v') {
			collect_sibling_rows(path, mut manifest)
		}
	} else {
		return ''
	}
	root := if os.is_dir(path) { path } else { os.dir(path) }
	vmod := os.read_file(os.join_path(root, 'v.mod')) or { '' }
	if vmod.len > 0 {
		manifest << 'v.mod\x1f${sha256.sum(vmod.bytes()).hex()[..16]}'
	}
	return sha256.sum(manifest.join('\n').bytes()).hex()
}

// collect_source_rows appends `relpath\x1fhash16` rows for every .v file
// under dir, recursion in sorted order for determinism; hidden directories
// (a .git worktree can hold stale sources) and node_modules trees are
// skipped, consistent with v_where.
fn collect_source_rows(dir string, prefix string, mut rows []string) {
	mut entries := os.ls(dir) or { return }
	entries.sort()
	for entry in entries {
		full := os.join_path(dir, entry)
		if os.is_dir(full) {
			if entry.starts_with('.') || entry == 'node_modules' {
				continue
			}
			collect_source_rows(full, join_rel(prefix, entry), mut rows)
		} else if entry.ends_with('.v') {
			src := os.read_file(full) or {
				rows << '${join_rel(prefix, entry)}\x1funreadable'
				continue
			}
			rows << '${join_rel(prefix, entry)}\x1f${sha256.sum(src.bytes()).hex()[..16]}'
		}
	}
}

// join_rel builds a `src/main.v` relative name from a walker prefix and entry.
fn join_rel(prefix string, entry string) string {
	return if prefix == '' { entry } else { '${prefix}/${entry}' }
}

// collect_sibling_rows hashes the other .v files beside a `_test.v` target.
// V's compile unit for a test file reaches past the file itself: the module
// siblings of its directory are pulled in beside it (probed both ways — `v
// test lib_test.v` reports a sibling's syntax error that `v lib.v` alone
// compiles through). A key missing them replayed stale records, which is
// what made v_errors answer `[]` for test files in a broken module and
// replay failure rows after the sibling was fixed; hashing the directory's
// .v content puts the true compile unit in the identity. Plain file targets
// compile on their own, so only test targets pay this key input.
fn collect_sibling_rows(path string, mut rows []string) {
	dir := os.dir(path)
	file_name := os.file_name(path)
	sibs := os.ls(dir) or { return }
	mut names := sibs.filter(it.ends_with('.v') && it != file_name)
	names.sort()
	for name in names {
		src := os.read_file(os.join_path(dir, name)) or {
			rows << '${name}\x1funreadable'
			continue
		}
		rows << '${name}\x1f${sha256.sum(src.bytes()).hex()[..16]}'
	}
}

// cache_load returns the stored record for key, or none when absent/bad.
fn cache_load(key string) ?CachedBuild {
	if key == '' {
		return none
	}
	data := os.read_file(os.join_path(cache_dir(), key, 'result.json')) or { return none }
	return json2.decode[CachedBuild](data, json2.DecoderOptions{}) or { none }
}

// cache_save writes the record for key into its entry dir; a non-empty bin
// path is moved under the entry as the reusable executable.
fn cache_save(key string, record CachedBuild, bin string) {
	if key == '' {
		return
	}
	entry := os.join_path(cache_dir(), key)
	os.mkdir_all(entry) or { return }
	os.write_file(os.join_path(entry, 'result.json'), json2.encode(record)) or { return }
	if bin != '' && os.exists(bin) {
		os.mv(bin, os.join_path(entry, 'bin')) or { return }
	}
}

// prune_cache bounds the entry count: everything older than the age cap is
// dropped, then all but the newest cache_keep_entries. Runs once from main
// before the stdio loop starts.
fn prune_cache() {
	entries := os.ls(cache_dir()) or { return }
	stamp := time.now().unix() - i64(cache_max_age_hours) * time.hour
	mut by_mtime := []string{}
	for entry in entries {
		if entry == 'toolchain.txt' {
			continue
		}
		full := os.join_path(cache_dir(), entry)
		if !os.is_dir(full) {
			continue
		}
		filestat := os.stat(full) or { continue }
		if filestat.mtime < stamp {
			os.rmdir_all(full) or {}
			continue
		}
		// zero-padded mtime first ⇒ plain string sorting orders oldest first
		by_mtime << '${filestat.mtime:020}\x1f${entry}'
	}
	if by_mtime.len <= cache_keep_entries {
		return
	}
	by_mtime.sort()
	oldest := by_mtime[0..by_mtime.len - cache_keep_entries].clone()
	for row in oldest {
		entry_name := row.after('\x1f')
		if entry_name.len > 0 {
			os.rmdir_all(os.join_path(cache_dir(), entry_name)) or {}
		}
	}
}

// build_with_cache is the compile step with the warm cache in front: on a
// key hit the stored record (and binary, when stored) is replayed and no v
// process runs; on a miss it compiles to a temp output and stores the
// record. `seconds` is the per-call cap for the compile spawn (the server
// default is tool_timeout_seconds). An empty key (out-of-scope target)
// skips both cache and save.
fn build_with_cache(path string, flags []string, seconds int) BuildOutcome {
	key := build_cache_key(path, flags)
	if key != '' {
		if rec := cache_load(key) {
			entry_bin := os.join_path(cache_dir(), key, 'bin')
			return BuildOutcome{
				ok:       rec.ok
				text:     rec.text
				summary:  rec.summary
				hit:      true
				bin_path: if os.is_file(entry_bin) { entry_bin } else { '' }
			}
		}
	}
	return compile_and_store(path, flags, key, seconds)
}

// compile_and_store is the miss path: run v against a temp output (seconds
// = the call's cap), fold the capture into a record (text capped, with a
// summary for stream-empty failures), store it under key when there is one,
// and return the facts — with the freshly built binary to execute when the
// compile succeeded.
fn compile_and_store(path string, flags []string, key string, seconds int) BuildOutcome {
	tmp := tmp_output_path('cache_target')
	compile := compile_capture(compile_args(tmp, path, flags), seconds)
	ok := compile.exit_code == 0 && !compile.timed_out
	text := merge_streams(compile.stdout, compile.stderr)
	summary := if compile.timed_out {
		'command timed out after ${seconds} s'
	} else if compile.exit_code != 0 {
		'command failed with exit code ${compile.exit_code}'
	} else {
		''
	}
	record := CachedBuild{
		ok:      ok
		text:    if text.len > cache_max_stored_bytes { truncate(text) } else { text }
		summary: summary
	}
	if key != '' {
		cache_save(key, record, if ok { os.real_path(tmp) } else { '' })
	}
	// the saved move puts the binary in the entry (and keeps it running for
	// this call too); with no entry — empty key or a failed move — the temp
	// output is the executable
	mut bin_path := if ok && os.is_file(tmp) { tmp } else { '' }
	if ok && key != '' {
		entry_bin := os.join_path(cache_dir(), key, 'bin')
		if os.is_file(entry_bin) {
			bin_path = entry_bin
		}
	}
	return BuildOutcome{
		ok:       ok
		text:     record.text
		summary:  record.summary
		hit:      false
		bin_path: bin_path
	}
}

// ---- tools -----------------------------------------------------------------

fn v_build_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[BuildArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	flags := a.vflags or { []string{} }
	validate_vflags(flags) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	// The run_v_tool text contract, rebuilt from the record: failures carry
	// what the compiler printed (or the summary when it printed nothing);
	// successes report 'ok'.
	outcome := build_with_cache(a.path, flags, tool_timeout_seconds)
	if !outcome.ok {
		return to_error_result(if outcome.text.len == 0 { outcome.summary } else { outcome.text })
	}
	out := if outcome.text.len == 0 { 'ok (exit 0, no output)' } else { outcome.text }
	return mcp.tool_text_result(truncate(out))
}

// ---- v_run: compile once, then execute the binary ---------------------------

// program_stdin_cmd builds the sh(1) invocation that runs bin with stdin
// redirected from a one-off file. Inside the script $1 is the file (f="$1"
// remembers it), shift promotes bin to $1, and exec replaces the shell with
// `bin args... < file`: every variable byte — binary path, arguments, input
// file — travels as argv, re-quoted only by "$@", so nothing user-supplied
// is parsed by the shell; exec folds the shell away, keeping the timeout
// machinery on the program's pid.
fn program_stdin_cmd(bin string, args []string, stdin_path string) []string {
	mut cmd := []string{cap: 6 + args.len}
	cmd << 'sh'
	cmd << '-c'
	// $1 = stdin_path, $2 = bin, $3.. = args: save the file, drop it, run what is left
	cmd << 'f="$1"; shift; exec "$1" "$@" <"$f"'
	cmd << 'v_run' // sh's invocation name ($0) — never inspected
	cmd << stdin_path
	cmd << bin
	cmd << args
	return cmd
}

// run_built_program executes a freshly built (or cache-replayed) binary for
// v_run and v_scratch. With stdin the program runs through a one-off temp
// file (see program_stdin_cmd); without it, straight from the binary with
// argv — a stdin-reading program sees EOF immediately (run_capture gives
// every child /dev/null). Same exit-code and stream contract either way.
fn run_built_program(bin string, args []string, stdin string, seconds int) !Capture {
	if stdin != '' {
		stdin_path := tmp_output_path('stdin')
		os.write_file(stdin_path, stdin)!
		defer {
			os.rm(stdin_path) or {}
		}
		return run_capture(program_stdin_cmd(bin, args, stdin_path), seconds)
	}
	mut pargs := []string{cap: args.len + 1}
	pargs << bin
	pargs << args
	return run_capture(pargs, seconds)
}

// present_program_run formats one compiled program run as a tool result —
// the output shape shared by v_run and v_scratch: labeled streams, the
// compiler's own chatter ahead when the build printed any (a quiet, clean
// build prints none), and the timeout / exit-code verdict last.
fn present_program_run(outcome BuildOutcome, prog Capture, seconds int) mcp.ToolResult {
	mut parts := []string{}
	if outcome.text.len > 0 {
		parts << 'compiler output:\n${outcome.text}'
	}
	if prog.stdout.len > 0 {
		parts << 'program stdout:\n${prog.stdout.trim_space()}'
	}
	if prog.stderr.len > 0 {
		parts << 'program stderr:\n${prog.stderr.trim_space()}'
	}
	if prog.timed_out {
		parts << 'program timed out after ${seconds} s'
		return to_error_result(truncate(parts.join('\n')))
	}
	if prog.exit_code != 0 {
		parts << 'program exited with code ${prog.exit_code}'
		return to_error_result(truncate(parts.join('\n')))
	}
	if parts.len == 0 {
		parts << 'ok (exit 0, no output)'
	}
	return mcp.tool_text_result(truncate(parts.join('\n')))
}

fn v_run_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[RunArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}

	// Same failure contract as run_v_tool: an error result carrying whatever
	// the compiler printed (or a fallback line when it printed nothing). The
	// warm cache may hold a build for these exact sources — then no compile
	// step runs: the stored binary (and the stored compiler text) replay.
	flags := a.vflags or { []string{} }
	validate_vflags(flags) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	seconds := resolve_timeout(a.timeout) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	// The compile spawn is infrastructure and keeps the server-wide cap —
	// v_scratch's compile already runs under exactly that fixed budget. The
	// `timeout` override answers "how long may the program run": feeding it
	// to the compile let a small cap kill the build before the program ever
	// ran (CI run 27 replayed this: a 2 s override, a pid-unique scratch
	// target and a partially warm cache made the build exceed 2 s and the
	// reply read "v_run build failed:\ncommand timed out after 2 s").
	outcome := build_with_cache(a.path, flags, tool_timeout_seconds)
	if !outcome.ok {
		build_log := if outcome.text.len == 0 { outcome.summary } else { outcome.text }
		return to_error_result('v_run build failed:\n${build_log}')
	}

	args := a.args or { []string{} }
	prog := run_built_program(outcome.bin_path, args, a.stdin or { '' }, seconds)!
	return present_program_run(outcome, prog, seconds)
}

// ---- v_scratch: projectless snippets ----------------------------------------

// scratch_dir roots the snippet files under the system temp tree, one dir
// per server process: the server never writes inside an agent's project for
// a throwaway compile.
fn scratch_dir() string {
	return os.join_path(os.temp_dir(), 'v-mcp-scratch-${os.getpid()}')
}

// scratch_source_path content-addresses a snippet to a .v file: identical
// snippets reuse one file (and one warm-cache record), distinct snippets
// never touch the same name.
fn scratch_source_path(code string) string {
	hash := sha256.sum(code.bytes()).hex()[..8]
	return os.join_path(scratch_dir(), 's_${hash}.v')
}

fn v_scratch_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[ScratchArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	flags := a.vflags or { []string{} }
	validate_vflags(flags) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}

	// The source lands on disk content-addressed (see scratch_source_path),
	// where build_cache_key reads it. Nothing is deleted after the call:
	// a later identical snippet re-derives the same key and replays the
	// cache entry — the files are tiny and the dir is per-process.
	src := scratch_source_path(a.code)
	os.mkdir_all(scratch_dir())!
	os.write_file(src, a.code)!

	// Same failure contract as v_run: an error result carrying whatever the
	// compiler printed (or a fallback line when it printed nothing).
	outcome := build_with_cache(src, flags, tool_timeout_seconds)
	if !outcome.ok {
		build_log := if outcome.text.len == 0 { outcome.summary } else { outcome.text }
		return to_error_result('v_scratch build failed:\n${build_log}')
	}

	prog := run_built_program(outcome.bin_path, [], a.stdin or { '' }, tool_timeout_seconds)!
	return present_program_run(outcome, prog, tool_timeout_seconds)
}

// ---- v_errors: compile-only, structured diagnostics -------------------------

fn v_errors_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[BuildArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	flags := a.vflags or { []string{} }
	validate_vflags(flags) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	seconds := resolve_timeout(a.timeout) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	if l := a.limit {
		if l < 1 {
			return to_error_result('bad arguments: limit must be an integer ≥ 1 (or omit it)')
		}
	}
	outcome := build_with_cache(a.path, flags, seconds)
	diags := parse_diagnostics(outcome.text)
	if diags.len == 0 && !outcome.ok {
		// failed without parseable diagnostics — surface it once instead of
		// letting `[]` pass as a clean build: the summary (always set for a
		// failed compile) explains, the captured text follows
		return to_error_result('v_errors: ${outcome.summary}:\n${truncate(outcome.text)}')
	}
	return mcp.tool_text_result(truncate(diagnostics_body(diags, a.limit or { 0 })))
}

// diagnostics_body renders the v_errors reply: the plain JSON row array —
// the shape `[]` means clean — or, when a positive limit cuts a longer row
// list short, an object {rows,total,truncated:true} so the agent sees both
// the cap and the full count. limit < 1 keeps the plain array (no cap).
fn diagnostics_body(diags []Diagnostic, limit int) string {
	if limit < 1 || diags.len <= limit {
		return json2.encode(diags)
	}
	return json2.encode(TruncatedDiags{
		rows:      diags[..limit]
		total:     diags.len
		truncated: true
	})
}

// parse_diagnostics extracts one-line compiler diagnostics from `v` output —
// header lines shaped `file.v:LINE:COL: kind: message` (kind: error,
// warning, note — `builder error` counts as error). Source-context lines and
// anything else pass by. Equal consecutive headers are deduplicated, since
// the same diagnostic can surface in both captured streams.
fn parse_diagnostics(text string) []Diagnostic {
	mut diags := []Diagnostic{}
	for raw_line in text.split_into_lines() {
		line := raw_line.trim_space()
		parts := line.split(':')
		if parts.len < 4 || !parts[0].ends_with('.v') {
			continue
		}
		src_line := parts[1].int()
		src_col := parts[2].int()
		if src_line < 1 || src_col < 1 {
			continue
		}
		rest := parts[3..].join(':').trim_space()
		mut kind_word := rest
		mut msg := ''
		sep := rest.index(': ') or { -1 }
		if sep >= 0 {
			kind_word = rest[..sep]
			msg = rest[sep + 2..]
		}
		kind := diagnostic_kind(kind_word)
		if kind == '' {
			continue
		}
		d := Diagnostic{ file: parts[0], line: src_line, col: src_col, kind: kind, message: msg }
		if diags.any(it == d) {
			continue
		}
		diags << d
	}
	return diags
}

// diagnostic_kind maps a severity word to one of error/warning/note, or ''
// when the word is not a severity.
fn diagnostic_kind(word string) string {
	return if word.contains('error') {
		'error'
	} else if word.contains('warning') {
		'warning'
	} else if word.contains('note') {
		'note'
	} else {
		''
	}
}

// TestRow is one parsed `v -stats test` result line, attributed to the file
// the row's `running tests in:` cue set. Failing rows carry the failure
// context `v` prints above them: `at` names the header line (file:line + fn)
// and `detail` holds the failing statement plus any captured values.
struct TestRow {
pub:
	file    string
	name    string
	ok      bool
	ms      f64
	asserts int
	at      string
	detail  string
}

// GateSection is one v_gate check verdict: the ok flag plus the detail text
// (drifted file list, vet warnings, raw test output) and — for tests — the
// parsed rows.
struct GateSection {
pub:
	ok     bool
	rows   []TestRow
	detail string
}

// GateReport is the composite v_gate reply: the two static checks, the
// affected test subset, the executed-tests section (exercises nothing when
// tests_run is false), and the overall verdict — the tool is an error
// result while ok=false.
struct GateReport {
pub:
	fmt_check GateSection
	vet       GateSection
	affected  []string
	tests_run bool
	tests     GateSection
	ok        bool
}

// test_context_lines bounds how many failure-context lines one FAIL row
// carries: `v -stats` prints the header + failing statement + captured
// values above each FAIL result line (panic-style traces can be longer, but
// they kill the runner before a FAIL row even lands).
const test_context_lines = 8

// parse_test_rows extracts one row per test result from `v -stats test`
// output. File attribution comes from the `running tests in:` cues; result
// lines are shaped `     OK    [1/2]     0.000 ms     1 assert | mod.fn()`
// (FAIL counts the same). FAIL rows carry `at` and `detail`: the header line
// (`file:LINE: fn name`) and the source context above the row. Unrelated
// lines pass by; a result line whose shape does not fit yields no row, and
// no rows at all means the caller falls back to the raw output.
fn parse_test_rows(text string) []TestRow {
	mut rows := []TestRow{}
	mut file := ''
	mut context := []string{}
	for raw_line in text.split_into_lines() {
		line := raw_line.trim_space()
		if line.starts_with('running tests in: ') {
			file = line.after('running tests in: ').trim_space()
			context.clear()
			continue
		}
		mut kind := ''
		if line.starts_with('OK ') {
			kind = 'OK'
		} else if line.starts_with('FAIL ') {
			kind = 'FAIL'
		}
		// a result-shaped line either parses into a row or is junk —
		// dropped here, never buffered as failure context; every other
		// line falls through to the context buffer below
		if kind != '' {
			sep := line.index(' | ') or { continue }
			fields := line[..sep].trim_space().fields()
			tail := line[sep + 3..].trim_space()
			if fields.len < 6 || !fields[1].starts_with('[') || fields[3] != 'ms' {
				continue
			}
			if !tail.ends_with('()') || !tail.contains('.') {
				continue
			}
			// the failure context `v` prints above a FAIL row: its header
			// line (`file:LINE: fn name`) becomes at, the rest becomes
			// detail (the failing statement plus captured values)
			mut fail_at := ''
			mut fail_detail := ''
			if kind == 'FAIL' && context.len > 0 {
				mut head := -1
				for idx, cline in context {
					if cline.contains(': fn ') {
						head = idx
						break
					}
				}
				if head >= 0 {
					fail_at = context[head]
					fail_detail = context[head + 1..].join('\n').trim_space()
				} else {
					fail_detail = context.join('\n').trim_space()
				}
			}
			rows << TestRow{
				file:    file
				name:    tail[..tail.len - 2]
				ok:      kind == 'OK'
				ms:      fields[2].f64()
				asserts: fields[4].int()
				at:      fail_at
				detail:  fail_detail
			}
			context.clear()
			continue
		}
		context << line
		if context.len > test_context_lines {
			context.delete(0)
		}
	}
	return rows
}

// test_report renders the structured v_test view: a one-line count, one JSON
// row per test result, and the raw -stats output as failure detail whenever
// anything failed.
fn test_report(rows []TestRow, raw string) string {
	passed := rows.filter(it.ok).len
	mut out := 'tests: ${passed}/${rows.len} passed\n' + json2.encode(rows)
	if passed < rows.len {
		out += '\n\nfailure detail:\n' + raw.trim_space()
	}
	return out
}

// env_test_filter_prefix assembles the env(1) filter section shared by the
// plain and structured v_test branches: each filter is either set verbatim
// (when the caller asked for it) or explicitly unset — this server often
// runs itself under a narrowed `v test` harness, and inherited filters would
// silently exclude every test of the call. The filters travel through env(1)
// because set_environment would *replace* the child environment outright
// (PATH, HOME and friends would vanish), while env(1) appends to the
// inherited environment. VTEST_ONLY filters test file paths, VTEST_ONLY_FN
// test function names, and every -u comes before any assignment: env(1)
// stops parsing options at the first VAR=val, later flags are the command.
fn env_test_filter_prefix(only string, files string) []string {
	mut env := []string{}
	// the clears (wanted or not, they must precede every assignment)
	if only == '' {
		env << '-u'
		env << 'VTEST_ONLY_FN'
	}
	if files == '' {
		env << '-u'
		env << 'VTEST_ONLY'
	}
	// the assignments
	if only != '' {
		env << 'VTEST_ONLY_FN=${only}'
	}
	if files != '' {
		env << 'VTEST_ONLY=${files}'
	}
	return env
}

fn v_test_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[TestArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	only := a.only or { '' }.trim_space()
	files := a.files or { '' }.trim_space()
	// both filters travel verbatim through env(1); reject anything no
	// pattern needs before it ever reaches a process (an empty pattern
	// validates trivially)
	validate_filter(only) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_filter(files) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	seconds := resolve_timeout(a.timeout) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	filters := env_test_filter_prefix(only, files)
	stats := a.stats or { false }
	if !stats {
		mut cmd := []string{cap: 6 + filters.len}
		cmd << 'env'
		cmd << filters
		cmd << 'v'
		cmd << '-no-parallel'
		cmd << 'test'
		cmd << a.path
		return run_v_tool(cmd, seconds)
	}
	// structured mode: `-stats` output parses into one row per test result;
	// same filter hygiene as the plain branch above
	mut cmd := []string{}
	cmd << 'env'
	cmd << filters
	cmd << 'v'
	cmd << '-stats'
	cmd << '-no-parallel'
	cmd << 'test'
	cmd << a.path
	c := run_capture(cmd, seconds)
	text := merge_streams(c.stdout, c.stderr)
	rows := parse_test_rows(text)
	if rows.len == 0 {
		// nothing parseable: the tests failed to compile, the suite never
		// ran, or the -stats shape changed — fall back to the raw view
		// (plus a timeout note when the run hit the process cap)
		if c.exit_code != 0 || c.timed_out {
			fallback := if c.timed_out {
				'test run timed out after ${seconds} s'
			} else {
				text
			}
			return to_error_result('v_test: exit ${c.exit_code}, no parseable rows:\n${fallback}')
		}
		return mcp.tool_text_result(truncate(text))
	}
	// the run itself failed — a partial suite (rows parsed for the files
	// that ran before a panic or a later compile failure) still shows as
	// rows: the verdict is an error either way, and the raw view follows
	// when the rows carry no failure detail of their own
	mut report := test_report(rows, text)
	if c.exit_code != 0 || c.timed_out {
		if !report.contains('failure detail:') {
			report += '\n\nraw view (the run did not finish cleanly):\n' + text.trim_space()
		}
		return to_error_result(truncate(report))
	}
	return mcp.tool_text_result(truncate(report))
}

// ---- v_gate: the one-call commit gate ---------------------------------------

// v_gate_tool composes the whole pre-commit loop in one call: `v fmt -c`
// (drift names the files), `v vet` (warnings informational — they surface as
// detail, and only non-zero exits fail the gate), the affected test subset
// (git diff + import graph), and — under run_tests — the narrowed `-stats`
// test run with the affected files as the VTEST_ONLY filter. The reply is
// one JSON report of sections; the tool itself is an error result while the
// verdict ok=false.
fn v_gate_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[GateArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}

	// formatting: exit non-zero when anything drifts; the merged streams
	// name the files, silence with exit 0 is clean
	c := run_capture(['v', 'fmt', '-c', a.path], tool_timeout_seconds)
	fmt_ok := c.exit_code == 0 && !c.timed_out
	mut fmt_detail := merge_streams(c.stdout, c.stderr).trim_space()
	if fmt_detail == '' && !fmt_ok {
		fmt_detail = 'v fmt -c exited with code ${c.exit_code} (no output)'
	}

	// vet: warnings do not fail the gate (they arrive as detail text);
	// non-zero exit or a killed process does
	vc := run_capture(['v', 'vet', a.path], tool_timeout_seconds)
	vet_ok := vc.exit_code == 0 && !vc.timed_out
	vet_detail := merge_streams(vc.stdout, vc.stderr).trim_space()

	// the affected subset — undeterminable is a gate failure
	affected_files := affected_test_files(a.path, a.base or { '' }) or {
		return to_error_result('v_gate: affected set: ${err.msg()}')
	}

	// the optional narrowed test run: VTEST_ONLY carries the affected files
	run := a.run_tests or { false }
	mut tests_section := GateSection{ ok: true, detail: '' }
	if run {
		if affected_files.len == 0 {
			tests_section = GateSection{ ok: true, detail: 'not run: nothing affected' }
		} else {
			files := affected_files.join(',')
			validate_filter(files) or {
				return to_error_result('v_gate: affected files filter: ${err.msg()}')
			}
			filters := env_test_filter_prefix('', files)
			mut cmd := []string{}
			cmd << 'env'
			cmd << filters
			cmd << 'v'
			cmd << '-stats'
			cmd << '-no-parallel'
			cmd << 'test'
			cmd << a.path
			tc := run_capture(cmd, tool_timeout_seconds)
			text := merge_streams(tc.stdout, tc.stderr)
			rows := parse_test_rows(text)
			if rows.len == 0 {
				// nothing parseable: the tests failed to compile, the suite
				// never started, or the -stats shape changed — the raw text
				// is the detail
				tests_section = GateSection{
					ok:     tc.exit_code == 0 && !tc.timed_out
					detail: if tc.timed_out {
						'test run timed out after ${tool_timeout_seconds} s'
					} else {
						text.trim_space()
					}
				}
			} else {
				run_ok := tc.exit_code == 0 && !tc.timed_out && rows.all(it.ok)
				// rows explain a row-level failure; a run that died without
				// any FAIL row (a panic) gets the raw text as its detail
				detail := if !run_ok && rows.all(it.ok) { text.trim_space() } else { '' }
				tests_section = GateSection{ ok: run_ok, rows: rows, detail: detail }
			}
		}
	}

	report := GateReport{
		fmt_check: GateSection{ ok: fmt_ok, detail: fmt_detail }
		vet:       GateSection{ ok: vet_ok, detail: vet_detail }
		affected:  affected_files
		tests_run: run
		tests:     tests_section
		ok:        fmt_ok && vet_ok && (!run || tests_section.ok)
	}
	body := json2.encode(report)
	return if report.ok {
		mcp.tool_text_result(truncate(body))
	} else {
		to_error_result(body)
	}
}

// v_fmt_tool checks formatting without touching files: `v fmt -c` (exit
// non-zero when anything drifts). With `diff` the reply also carries the
// unified diff of what `v fmt` would change — `v fmt -diff`, ANSI-stripped.
fn v_fmt_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[FmtCheckArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	// no diff switch: the plain check, exit non-zero means drift
	if !(a.diff or { false }) {
		return run_v_tool(['v', 'fmt', '-c', a.path], tool_timeout_seconds)
	}
	// -c first: the file list names which files drift (`v fmt -diff` prints
	// no per-file headers). Empty list = no drift at all — done, one spawn.
	c := run_capture(['v', 'fmt', '-c', a.path], tool_timeout_seconds)
	files_list := merge_streams(c.stdout, c.stderr).trim_space()
	if files_list == '' {
		if c.timed_out {
			return to_error_result('command timed out after ${tool_timeout_seconds} s')
		}
		return mcp.tool_text_result('ok (exit 0, no output)')
	}
	d := run_capture(['v', 'fmt', '-diff', a.path], tool_timeout_seconds)
	diff_text := strip_ansi(merge_streams(d.stdout, d.stderr).trim_space())
	// a killed or quietly-failing diff spawn gets a labeled tail, so the
	// reply explains its own shape (the drift list still stands); the tail
	// is empty in the normal case
	tail := if d.timed_out {
		'\n\nv fmt -diff timed out after ${tool_timeout_seconds} s'
	} else if diff_text == '' && d.exit_code != 0 {
		'\n\nv fmt -diff exited with code ${d.exit_code} (no output)'
	} else {
		''
	}
	out := if diff_text == '' {
		files_list + tail
	} else {
		files_list + '\n\ndiff:\n' + diff_text + tail
	}
	return if c.exit_code != 0 || d.exit_code != 0 || d.timed_out {
		to_error_result(out)
	} else {
		mcp.tool_text_result(truncate(out))
	}
}

// strip_ansi removes terminal color escape sequences (ESC [ … m and friends)
// from tool output: the `v fmt -diff` report colors its hunks, and raw
// escape codes only pollute an agent's context.
fn strip_ansi(text string) string {
	if !text.contains('\x1b') {
		return text
	}
	mut out := []u8{cap: text.len}
	mut i := 0
	for i < text.len {
		if text[i] == 27 && i + 1 < text.len && text[i + 1] == `[` {
			// skip the parameter bytes (digits, ';', '?') to the final letter
			mut j := i + 2
			for j < text.len && (text[j].is_digit() || text[j] == `;` || text[j] == `?`) {
				j++
			}
			// a sequence runs to its final letter; anything less (output
			// cut mid-sequence) is not a sequence — its bytes pass through
			// verbatim. The bounds check gates the letter test: j can sit
			// at text.len
			if j < text.len
				&& ((text[j] >= `a` && text[j] <= `z`) || (text[j] >= `A` && text[j] <= `Z`)) {
				i = j + 1
				continue
			}
		}
		out << text[i]
		i++
	}
	return out.bytestr()
}

// v_fmt_fix_tool closes the formatting loop: it runs `v fmt -w`, which
// rewrites the touched files in place (use v_fmt_check to only verify).
fn v_fmt_fix_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	return run_v_tool(['v', 'fmt', '-w', a.path], tool_timeout_seconds)
}

fn v_vet_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	return run_v_tool(['v', 'vet', a.path], tool_timeout_seconds)
}

fn v_ast_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	// `-p` prints the AST JSON to stdout instead of writing a sidecar file.
	return run_v_tool(['v', 'ast', '-p', a.path], tool_timeout_seconds)
}

// ---- v_symbols: a pure-V symbol outline (no subprocess) ---------------------

struct Symbol {
pub:
	kind string
	name string
	line int
}

// symbols_from_file extracts a rough public-symbol outline: fns, structs,
// interfaces, enums, consts, types and methods. Zero-dependency on purpose;
// for full navigation use v-analyzer.
fn symbols_from_file(path string) []Symbol {
	mut syms := []Symbol{}
	content := os.read_file(path) or { return syms }
	for i, raw_line in content.split_into_lines() {
		line := raw_line.trim_space()
		kind := if line.starts_with('pub fn (') {
			'method'
		} else if line.starts_with('pub fn ') || line.starts_with('fn ') {
			'fn'
		} else if line.starts_with('pub struct ') || line.starts_with('struct ') {
			'struct'
		} else if line.starts_with('pub interface ') || line.starts_with('interface ') {
			'interface'
		} else if line.starts_with('pub enum ') || line.starts_with('enum ') {
			'enum'
		} else if line.starts_with('pub const ') || line.starts_with('const ') {
			'const'
		} else if line.starts_with('pub type ') || line.starts_with('type ') {
			'type'
		} else {
			''
		}
		if kind == '' {
			continue
		}
		name := symbol_name_of(kind, raw_line)
		if name.len > 0 {
			syms << Symbol{ kind: kind, name: name, line: i + 1 }
		}
	}
	return syms
}

// symbol_name_of pulls the identifier right after the declaration keyword
// (or the first identifier inside the params, for receiver methods).
fn symbol_name_of(kind string, raw_line string) string {
	toks := raw_line.trim_space().split(' ').filter(it.len > 0)
	if kind == 'method' {
		return method_name(toks)
	}
	for j, token in toks {
		if token == kind && j + 1 < toks.len {
			return toks[j + 1].split('(')[0].split(':')[0]
		}
	}
	return ''
}

// method_name decodes `pub fn (mut s Server) add_tool(...)` → `add_tool`.
fn method_name(toks []string) string {
	for _, token in toks {
		if token.starts_with(')') || token.contains(') ') {
			after := token.after(')')
			trimmed := after.trim_space()
			if trimmed.len > 0 {
				return trimmed.split('(')[0].split(':')[0]
			}
		}
	}
	return if toks.len > 0 { toks[toks.len - 1].split('(')[0].split(':')[0] } else { '' }
}

fn v_symbols_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	syms := symbols_from_file(a.path)
	if syms.len == 0 {
		return mcp.tool_text_result('(no symbols found in ${a.path}; only .v files with top-level declarations)')
	}
	mut b := []string{}
	for s in syms {
		b << '${s.line}\t${s.kind}\t${s.name}'
	}
	return mcp.tool_text_result(truncate('line\tkind\tname\n' + b.join('\n')))
}

// SymbolSource is a v_read slice: the verbatim text and its 1-based line
// range inside the source file.
struct SymbolSource {
	text string
	from int
	to   int
}

// symbol_source returns the verbatim source of one declared symbol (a
// top-level fn/method/struct/interface/enum/const/type in a .v file): from
// its header — including the doc comment block directly above it — to just
// before the next declaration, whose own comment block and the blank lines
// separating sections are trimmed back off.
fn symbol_source(path string, symbol string) !SymbolSource {
	syms := symbols_from_file(path)
	matches := syms.filter(it.name == symbol)
	if matches.len == 0 {
		return error('no symbol named "${symbol}" in ${path} (declared: ${syms.map(it.name).join(', ')})')
	}
	target := matches[0]
	content := os.read_file(path)!
	lines := content.split_into_lines()
	start_idx := target.line - 1
	if start_idx >= lines.len {
		return error('symbol line ${target.line} is out of range for ${path}')
	}
	mut first_idx := start_idx
	// the target's own doc comment block belongs to it
	for first_idx > 0 && lines[first_idx - 1].trim_space().starts_with('//') {
		first_idx--
	}
	// the span runs to just before the next declaration (syms are scan-ordered)
	mut end_idx := lines.len - 1
	for next_decl in syms {
		if next_decl.line > target.line {
			end_idx = next_decl.line - 2
			break
		}
	}
	if end_idx < first_idx {
		end_idx = first_idx
	}
	// the next declaration's doc comments are its own, not part of this span
	for end_idx > start_idx {
		tail := lines[end_idx].trim_space()
		if tail == '' || tail.starts_with('//') {
			end_idx--
		} else {
			break
		}
	}
	return SymbolSource{
		text: lines[first_idx..end_idx + 1].join('\n')
		from: first_idx + 1
		to:   end_idx + 1
	}
}

// v_read_tool returns the exact source text of one symbol from a .v file —
// a pinpoint read next to v_symbols, so an agent editing a function in a
// long file never has to load the whole thing.
fn v_read_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[ReadArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	symbol := a.symbol.trim_space()
	if symbol.len == 0 {
		return to_error_result('v_read: the "symbol" argument is required (a name from the v_symbols outline)')
	}
	slice := symbol_source(a.path, symbol) or {
		return to_error_result('v_read: ${err.msg()}')
	}
	return mcp.tool_text_result(truncate('${a.path}:${slice.from}-${slice.to}\n${slice.text}'))
}

// ---- v_doc: generated module docs --------------------------------------------

// v_doc_tool documents a module: the `v doc` output for a module directory
// (path), so agents read generated docs instead of paging through source.
fn v_doc_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	return run_v_tool(['v', 'doc', a.path], tool_timeout_seconds)
}

// ---- v_deps: read a project's v.mod -----------------------------------------

// v_mod_summary returns the name/version/license/dependencies fields read
// from a project directory's v.mod — the parsing v_deps reports, extracted
// here so v_where can reuse it.
fn v_mod_summary(dir string) !string {
	vmod := os.join_path(dir, 'v.mod')
	content := os.read_file(vmod)!
	// A multiline `dependencies: [...]` leaks into continuation lines, so the
	// dependencies field streams until its closing bracket instead of
	// matching just the four well-known prefixes.
	lines := content.split_into_lines()
	mut fields := []string{}
	mut i := 0
	for i < lines.len {
		mut line := lines[i].trim_space()
		if line.starts_with('name:') || line.starts_with('version:') || line.starts_with('license:') {
			fields << line
			i++
		} else if line.starts_with('dependencies') {
			fields << line
			for !line.ends_with(']') {
				i++
				if i >= lines.len {
					break
				}
				line = lines[i].trim_space()
				fields << line
			}
			i++
		} else {
			i++
		}
	}
	return fields.join('\n')
}

fn v_deps_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	return mcp.tool_text_result(v_mod_summary(a.path) or {
		return to_error_result('no v.mod in ${a.path}: ${err.msg()}')
	})
}

// ---- v_where: find every v.mod project below a directory --------------------

// v_where_depth bounds how deep v_where recurses looking for v.mod files.
const v_where_depth = 4

// find_v_projects appends every directory under dir (dir itself included)
// holding a v.mod, recursing at most v_where_depth levels and skipping
// hidden directories (e.g. .git) and vendored node_modules trees.
fn find_v_projects(dir string, depth int, mut found []string) {
	if depth > v_where_depth {
		return
	}
	if os.exists(os.join_path(dir, 'v.mod')) {
		found << dir
	}
	mut entries := os.ls(dir) or { return }
	entries.sort()
	for entry in entries {
		full := os.join_path(dir, entry)
		if entry.starts_with('.') || entry == 'node_modules' || !os.is_dir(full) {
			continue
		}
		find_v_projects(full, depth + 1, mut found)
	}
}

// v_where_tool reports every V project (a folder holding a v.mod) under a
// directory (path), each with its v.mod identity — the bootstrap answer for
// agents that sit at a workspace root full of projects while every other
// tool demands an absolute project path.
fn v_where_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	if !os.is_dir(a.path) {
		return to_error_result('v_where: path must be a directory to scan (got ${a.path})')
	}
	mut projects := []string{}
	find_v_projects(a.path, 0, mut projects)
	if projects.len == 0 {
		return mcp.tool_text_result('no v.mod projects under ${a.path} (depth ${v_where_depth})')
	}
	mut rows := []string{}
	for dir in projects {
		summary := v_mod_summary(dir) or { '' }
		if summary.len == 0 {
			rows << '${dir} — (v.mod unreadable)'
			continue
		}
		rows << '${dir} — ${summary.trim_space().replace('\n', ' ')}'
	}
	return mcp.tool_text_result(truncate(rows.join('\n')))
}

// ---- v_repo_brief: a compact repo map via the vrepo library ------------------

fn v_repo_brief_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	out := vrepo.brief(a.path, vrepo.Budget{}) or {
		return to_error_result('v_repo_brief: ${err.msg()}')
	}
	return mcp.tool_text_result(truncate(out))
}

// ---- v_affected: run-only-what-a-change-can-affect via the vaffected lib ----

// affected_test_files lists the *_test.v files a change can affect: git diff
// (vs base, default HEAD) names the changed .v files, and the vaffected
// library walks the static import graph from there. Shared by the v_affected
// tool and the v_gate commit-gate report.
fn affected_test_files(path string, base string) ![]string {
	b := if base != '' { base } else { 'HEAD' }
	// Changed paths come from git, relative to a.path; the library receives
	// them as plain data (same contract its CLI uses). Spawned like every
	// other child (run_capture): streams split, timeout cap applied.
	git := run_capture(['git', '-C', path, 'diff', '--name-only', b], tool_timeout_seconds)
	if git.exit_code != 0 || git.timed_out {
		reason := if git.timed_out {
			'git timed out after ${tool_timeout_seconds} s'
		} else {
			merge_streams(git.stdout, git.stderr)
		}
		return error('git diff failed: ${reason.trim_space()}')
	}
	mut changed := []string{}
	for row in git.stdout.split('\n') {
		mut p := row.trim_space()
		if p.starts_with('"') {
			p = p.trim_left('"').trim_right('"')
		}
		if p.len > 0 && p.ends_with('.v') {
			changed << p
		}
	}
	out := vaffected.affected_report(path, changed) or {
		return error('affected_report: ${err.msg()}')
	}
	mut files := []string{}
	for row in out.split('\n') {
		p := row.trim_space()
		if p.len > 0 {
			files << p
		}
	}
	return files
}

// v_affected_tool renders the affected-test list as plain text: one file per
// line (empty list means nothing to re-run).
fn v_affected_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[AffectedArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	files := affected_test_files(a.path, a.base or { '' }) or {
		return to_error_result('v_affected: ${err.msg()}')
	}
	if files.len == 0 {
		return mcp.tool_text_result('no affected tests (nothing to re-run)')
	}
	return mcp.tool_text_result(truncate(files.join('\n')))
}

// ---- v_uses: who-uses-what queries via the vuses library --------------------

fn v_uses_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[UsesArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	validate_path(a.path) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	symbol := a.symbol.trim_space()
	if symbol.len == 0 {
		return to_error_result('v_uses: the "symbol" argument is required (the declared name to query, e.g. run_v_tool)')
	}
	ix := vuses.analyze(a.path) or {
		return to_error_result('v_uses: ${err.msg()}')
	}
	return mcp.tool_text_result(truncate(ix.report(a.path, symbol)))
}

// v_server_info_tool reports the running build: the name/version constants,
// the @BUILD_TIMESTAMP baked into this binary at compile time, and the
// version of the v toolchain behind it — enough to spot a stale re-spawn in
// one call.
fn v_server_info_tool(_ctx mcp.Context, _arguments string) !mcp.ToolResult {
	ver := run_capture(['v', '-version'], tool_timeout_seconds)
	// @BUILD_TIMESTAMP bakes in as an epoch string; render it human-readable.
	build_time := time.unix(@BUILD_TIMESTAMP.i64()).str()
	mut out := '${server_name} ${server_version}\nbuilt at: ${build_time}'
	if ver.exit_code == 0 {
		out += '\n' + ver.stdout.trim_space()
	}
	return mcp.tool_text_result(out)
}

// ---- server wiring ----------------------------------------------------------

fn new_vlang_server() !mcp.Server {
	mut server := mcp.new_server(
		name:         server_name
		version:      server_version
		instructions: "V development server: compile, test (with a test-function glob only=… or a test-file filter files=…), format-check and format in place, vet, dump AST JSON, outline symbols, read one symbol's source (v_read), document a module, inspect v.mod, look up v.mod projects under a directory (v_where), brief a repo, run only affected tests, run a compiled program, run a standalone snippet with no project scaffolding (v_scratch), list compiler diagnostics as JSON, answer who-uses-what, take the one-call commit gate (v_gate: fmt + vet + affected tests, optionally run_tests), and report its own build (v_server_info). PASS ABSOLUTE PATHS."
	)
	server.add_tool(mcp.Tool{
		name:         'v_build'
		description:  'Compile a V file or project (path) and return compiler diagnostics. Optional vflags (JSON array of strings) are forwarded verbatim to the v CLI (e.g. ["-prod"] or ["-cc","clang"]).'
		input_schema: v_build_schema
	}, v_build_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_run'
		description:  'Compile path, then execute it. Optional args (JSON array of strings) are passed to the program; optional stdin (string) is piped to the program verbatim (no trailing newline added) and closed with EOF; optional timeout (integer seconds, 1..1800, default 600) raises the per-step cap; optional vflags (JSON array of strings) are forwarded to the compiler for the build. Returns the program output; compile failures return the compiler diagnostics as an error. Output caps apply.'
		input_schema: v_run_schema
	}, v_run_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_scratch'
		description:  'Compile and run a standalone V snippet (code) with zero project scaffolding: pass the complete source — a program with fn main, or plain top-level statements (V compiles those in script mode); nothing is wrapped. Optional stdin (string) is piped verbatim (no trailing newline, EOF afterwards); optional vflags (JSON array of strings) go to the compiler. Identical snippets replay the warm build cache. Output labeled and failure contract identical to v_run.'
		input_schema: v_scratch_schema
	}, v_scratch_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_errors'
		description:  'Compile only; return compiler diagnostics as JSON [{file,line,col,kind,message}] with kind error/warning/note. An empty array means the build is clean. Optional vflags (JSON array of strings) are forwarded to the compiler, mirroring the v_build command; optional timeout (integer seconds, 1..1800, default 600) raises the compile cap; optional limit (integer ≥ 1) caps the rows at the first N — when more rows exist the reply is an object {rows,total,truncated:true} instead of the array.'
		input_schema: v_errors_schema
	}, v_errors_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_test'
		description:  'Run `v test` on a file or project (path). Optional only (string) is a VTEST_ONLY_FN glob forwarded via env(1) — run only test functions whose name matches, e.g. "*handshake*". Optional files (string) is a VTEST_ONLY file filter forwarded via env(1) — run only test files whose relative path contains one of the comma-separated patterns, e.g. "parse_test.v"; pairs with the v_affected output. Optional stats (boolean) returns structured rows [{file,name,ok,ms,asserts}] — failing rows also carry at (the file:LINE: fn name header v prints above the row) and detail (the failing statement plus its captured values); the raw output trails as failure detail; unparsable runs fall back to the raw view; a failed run (failing tests, timeout, or a mid-run death) is an error result carrying the rows. Optional timeout (integer seconds, 1..1800, default 600) raises the whole-run cap.'
		input_schema: v_test_schema
	}, v_test_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_gate'
		description:  'One-call commit gate (path = project directory): formatting check (v fmt -c), vet (warnings ride along as detail, only real failures block), the affected *_test.v subset (git diff vs default HEAD or base), and — under optional run_tests (boolean) — the affected tests executed as a narrowed v -stats test run. Returns a JSON report {fmt_check,vet,affected,tests_run,tests,ok}; the tool is an error result while ok=false. Use it as the commit gate instead of chaining v_fmt_check + v_vet + v_affected + v_test.'
		input_schema: v_gate_schema
	}, v_gate_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_fmt_check'
		description:  'Run `v fmt -c` (check-only) on a file or directory (path). Non-zero exit if unformatted; use v_fmt to format in place. Optional diff (boolean) also returns the unified diff of what v fmt would change — the unformatted file list followed by the (ANSI-stripped) diff, error result while drift exists.'
		input_schema: fmt_check_schema
	}, v_fmt_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_fmt'
		description:  'Run `v fmt -w` (format in place) on a file or directory (path). Mutates source files; use v_fmt_check to only verify.'
		input_schema: path_args_schema
	}, v_fmt_fix_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_vet'
		description:  'Run `v vet` on a file or project (path) and return warnings.'
		input_schema: path_args_schema
	}, v_vet_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_ast'
		description:  'Dump the AST JSON of a V file (path) via `v ast -p`. Output capped.'
		input_schema: path_args_schema
	}, v_ast_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_symbols'
		description:  'List top-level symbols (fn/method/struct/interface/enum/const/type + line numbers) of a .v file (path).'
		input_schema: path_args_schema
	}, v_symbols_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_doc'
		description:  'Run `v doc` on a module directory (path) and return the generated module documentation.'
		input_schema: path_args_schema
	}, v_doc_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_deps'
		description:  'Read name/version/license/dependencies from the v.mod of a project (path).'
		input_schema: path_args_schema
	}, v_deps_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_repo_brief'
		description:  'Generate a compact token-efficient repo brief (module identity, entry points, file tree with LOC, per-file symbol outlines) of a V project directory (path). Deterministic; capped at ~40k chars.'
		input_schema: path_args_schema
	}, v_repo_brief_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_affected'
		description:  'List the *_test.v files a change can affect: diffs path against the optional git rev base (default HEAD) and propagates changed files backwards through the static import graph. Empty result means nothing to re-run.'
		input_schema: v_affected_schema
	}, v_affected_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_uses'
		description:  'Answer who-uses-what for a declared symbol: definitions (file:line per kind), call/constructor sites with the enclosing fn/method, and — when the symbol names an interface — approximated implementing types. Declared-name matching, comments and strings scrubbed. Text report, capped.'
		input_schema: v_uses_schema
	}, v_uses_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_read'
		description:  'Return the exact source text of one declared symbol (path = a .v file, symbol = its name, e.g. "run_capture"): from its header to just before the next declaration, with its range in the file. Pair with v_symbols for pinpoint edits without reading whole files.'
		input_schema: v_read_schema
	}, v_read_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_where'
		description:  'List every V project (a folder holding a v.mod) under directory path, up to a few levels deep — each with its v.mod name/version/license/dependencies, paths absolute and tool-ready.'
		input_schema: v_where_schema
	}, v_where_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_server_info'
		description:  'Report the running server build: name, version, compile-time build timestamp and the underlying `v -version`. No arguments. Use this to spot a stale binary/connection.'
		input_schema: server_info_schema
	}, v_server_info_tool)!
	return server
}

// main runs the MCP server over stdin/stdout (newline-delimited JSON-RPC).
// All logs go to stderr; stdout is reserved for the protocol.
fn main() {
	// one-time cache housekeeping: stamp the toolchain version (cache keys
	// depend on it) and bound the entry store
	refresh_toolchain_stamp()
	prune_cache()
	mut server := new_vlang_server() or {
		eprintln('${server_name}: failed to build server: ${err.msg()}')
		exit(1)
	}
	server.serve_stdio() or {
		eprintln('${server_name}: ${err.msg()}')
		exit(1)
	}
}
