// v-mcp-server
// An MCP (Model Context Protocol) server that exposes V development tooling
// to coding agents: program compilation and execution, structured build
// errors, test runs, formatting checks, vet warnings, AST dumps, symbol
// outlines, repo briefs, v.mod inspection and affected-test selection.
//
// Built on the official `mcp` module of the V standard library; serves
// over stdio (newline-delimited JSON-RPC), the transport used by Claude
// Code, OpenCode, Zed and friends.
module main

import mcp
import json2
import os
import time
import gil_silva.vrepo.vrepo
import gil_silva.vaffected.vaffected

const server_name = 'v-mcp-server'

const server_version = '0.3.0'

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

// v_run_schema declares path as required and args as optional argv; without
// args the program runs with none. `path` must stay the first property —
// smoke.vsh counts `"properties":{"path":{` occurrences server-wide.
const v_run_schema = '{"type":"object","properties":{"path":{"description":"Absolute path of a V file or project directory","type":"string"},"args":{"description":"Positional arguments passed to the compiled program (optional, JSON array of strings)","type":"array","items":{"type":"string"}}},"required":["path"],"additionalProperties":false}'

// PathArgs is the common `arguments` payload of the tools below:
// a path to a single .v file or a project directory.
struct PathArgs {
	path string
}

// RunArgs is the payload of v_run: path plus optional positional arguments
// (argv) forwarded to the compiled program.
struct RunArgs {
	path string
	args ?[]string
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

// AffectedArgs is the payload of v_affected: path plus the optional git rev
// to diff against ('HEAD' when absent).
struct AffectedArgs {
	path string
	base ?string
}

// decode_args parses a tool `arguments` JSON into T.
fn decode_args[T](arguments string) !T {
	return json2.decode[T](arguments, json2.DecoderOptions{})!
}

// tool_timeout_seconds caps any spawned `v` subcommand. The server processes
// tool calls sequentially, so one wedged child (a hung test runner, an
// interactive prompt) must not silently queue every other call behind it.
const tool_timeout_seconds = 600

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
// every 500 ms until tool_timeout_seconds (SIGTERM first, then SIGKILL
// after 3 s). Shared by run_v_tool, v_run and v_errors; each caller
// formats the Capture its own way.
fn run_capture(args []string) Capture {
	mut p := os.new_process(args[0])
	p.set_args(args[1..])
	p.set_redirect_stdio()
	p.run()
	start := time.now().unix()
	mut timed_out := false
	for p.is_alive() {
		if time.now().unix() - start > i64(tool_timeout_seconds) {
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
	defer {
		p.close()
	}
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
	if stderr.len > 0 {
		out += if out.len > 0 { '\n' } else { '' } + stderr
	}
	return out.trim_space()
}

// run_v_tool executes a `v` subcommand and wraps its output in an MCP tool
// result. A non-zero exit code yields an error result carrying both streams.
fn run_v_tool(args []string) mcp.ToolResult {
	c := run_capture(args)
	mut out := merge_streams(c.stdout, c.stderr)
	if c.exit_code != 0 || c.timed_out {
		if out.len == 0 {
			if c.timed_out {
				out = 'command timed out after ${tool_timeout_seconds} s'
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
fn truncate(text string) string {
	if text.len <= output_byte_limit {
		return text
	}
	return text[..output_byte_limit] + '\n... [truncated; ${text.len} bytes total]'
}

// tmp_output_path returns a unique absolute path for a temp build output.
fn tmp_output_path(tag string) string {
	return os.join_path(os.temp_dir(),
		'mcp_vlang_${tag}_${os.getpid()}_${time.now().unix().str()}_random_1')
}

// ---- tools -----------------------------------------------------------------

fn v_build_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	checkout := tmp_output_path('build')
	defer {
		os.rm(checkout) or {}
	}
	return run_v_tool(['v', '-o', checkout, '-no-parallel', a.path])
}

// ---- v_run: compile once, then execute the binary ---------------------------

fn v_run_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[RunArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	bin := tmp_output_path('run_target')
	defer {
		os.rm(bin) or {}
	}

	// Same failure contract as run_v_tool: an error result carrying whatever
	// the compiler printed (or a fallback line when it printed nothing).
	compile := run_capture(['v', '-o', bin, '-no-parallel', a.path])
	mut build_log := merge_streams(compile.stdout, compile.stderr)
	if compile.exit_code != 0 || compile.timed_out {
		if build_log.len == 0 {
			build_log = if compile.timed_out {
				'build timed out after ${tool_timeout_seconds} s'
			} else {
				'build failed with exit code ${compile.exit_code}'
			}
		}
		return to_error_result('v_run build failed:\n${build_log}')
	}

	args := a.args or { []string{} }
	mut pargs := []string{cap: args.len + 1}
	pargs << bin
	pargs << args

	prog := run_capture(pargs)
	program_text := merge_streams(prog.stdout, prog.stderr)
	mut parts := []string{}
	if build_log.len > 0 {
		parts << 'compiler output:\n${build_log}'
	}
	if program_text.len > 0 {
		parts << program_text
	}
	if prog.timed_out {
		parts << 'program timed out after ${tool_timeout_seconds} s'
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

// ---- v_errors: compile-only, structured diagnostics -------------------------

fn v_errors_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	bin := tmp_output_path('errors_target')
	defer {
		os.rm(bin) or {}
	}
	compile := run_capture(['v', '-o', bin, '-no-parallel', a.path])
	text := merge_streams(compile.stdout, compile.stderr)
	diags := parse_diagnostics(text)
	if diags.len == 0 && (compile.exit_code != 0 || compile.timed_out) {
		// Failed without parseable output; surface it raw instead of letting
		// `[]` pass as "clean build".
		fallback := if compile.timed_out {
			'build timed out after ${tool_timeout_seconds} s'
		} else {
			'build failed (exit ${compile.exit_code}) with no parseable diagnostics'
		}
		return to_error_result('v_errors: ${fallback}:\n${truncate(text)}')
	}
	body := json2.encode(diags)
	return mcp.tool_text_result(truncate(body))
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

fn v_test_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	return run_v_tool(['v', '-no-parallel', 'test', a.path])
}

fn v_fmt_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	// `v fmt -c` checks formatting without touching files (exit 1 if unformatted).
	return run_v_tool(['v', 'fmt', '-c', a.path])
}

fn v_vet_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	return run_v_tool(['v', 'vet', a.path])
}

fn v_ast_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	// `-p` prints the AST JSON to stdout instead of writing a sidecar file.
	return run_v_tool(['v', 'ast', '-p', a.path])
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
	syms := symbols_from_file(a.path)
	if syms.len == 0 {
		return mcp.tool_text_result('(no symbols found in ${a.path}; only .v files with top-level declarations)')
	}
	mut b := []string{}
	for s in syms {
		b << '${s.line}\t${s.kind}\t${s.name}'
	}
	return mcp.tool_text_result('line\tkind\tname\n' + b.join('\n'))
}

// ---- v_deps: read a project's v.mod -----------------------------------------

fn v_deps_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	vmod := os.join_path(a.path, 'v.mod')
	content := os.read_file(vmod) or {
		return to_error_result('no v.mod in ${a.path}: ${err.msg()}')
	}
	mut fields := []string{}
	for raw_line in content.split_into_lines() {
		line := raw_line.trim_space()
		if line.starts_with('name:') || line.starts_with('version:')
			|| line.starts_with('license:') || line.starts_with('dependencies') {
			fields << line
		}
	}
	return mcp.tool_text_result(fields.join('\n'))
}

// ---- v_repo_brief: a compact repo map via the vrepo library ------------------

fn v_repo_brief_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[PathArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	out := vrepo.brief(a.path, vrepo.Budget{}) or {
		return to_error_result('v_repo_brief: ${err.msg()}')
	}
	return mcp.tool_text_result(truncate(out))
}

// ---- v_affected: run-only-what-a-change-can-affect via the vaffected lib ----

fn v_affected_tool(_ctx mcp.Context, arguments string) !mcp.ToolResult {
	a := decode_args[AffectedArgs](arguments) or {
		return to_error_result('bad arguments: ${err.msg()}')
	}
	b := a.base or { 'HEAD' }
	base := if b.len > 0 { b } else { 'HEAD' }

	// Changed paths come from git, relative to a.path; the library receives
	// them as plain data (same contract its CLI uses).
	git := os.exec(['git', '-C', a.path, 'diff', '--name-only', base])
	if git.exit_code != 0 {
		return to_error_result('v_affected: git diff failed: ${git.output.trim_space()}')
	}
	mut changed := []string{}
	for row in git.output.split('\n') {
		mut p := row.trim_space()
		if p.starts_with('"') {
			p = p.trim_left('"').trim_right('"')
		}
		if p.len > 0 && p.ends_with('.v') {
			changed << p
		}
	}
	out := vaffected.affected_report(a.path, changed) or {
		return to_error_result('v_affected: ${err.msg()}')
	}
	text := if out.len == 0 { 'no affected tests (nothing to re-run)' } else { out }
	return mcp.tool_text_result(truncate(text))
}

// ---- server wiring ----------------------------------------------------------

fn new_vlang_server() !mcp.Server {
	mut server := mcp.new_server(
		name:         server_name
		version:      server_version
		instructions: 'V development server: compile, test, format-check, vet, dump AST JSON, outline symbols, inspect v.mod, brief a repo, run only affected tests, run a compiled program, list compiler diagnostics as JSON. PASS ABSOLUTE PATHS.'
	)
	server.add_tool(mcp.Tool{
		name:         'v_build'
		description:  'Compile a V file or project (path) and return compiler diagnostics.'
		input_schema: path_args_schema
	}, v_build_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_run'
		description:  'Compile path, then execute it. Optional args (JSON array of strings) are passed to the program. Returns the program output; compile failures return the compiler diagnostics as an error. Timeout and output caps apply.'
		input_schema: v_run_schema
	}, v_run_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_errors'
		description:  'Compile only; return compiler diagnostics as JSON [{file,line,col,kind,message}] with kind error/warning/note. An empty array means the build is clean.'
		input_schema: path_args_schema
	}, v_errors_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_test'
		description:  'Run `v test` on a file or project (path) and return results.'
		input_schema: path_args_schema
	}, v_test_tool)!
	server.add_tool(mcp.Tool{
		name:         'v_fmt_check'
		description:  'Run `v fmt -c` (check-only) on a file or directory (path). Non-zero exit if unformatted.'
		input_schema: path_args_schema
	}, v_fmt_tool)!
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
	return server
}

// main runs the MCP server over stdin/stdout (newline-delimited JSON-RPC).
// All logs go to stderr; stdout is reserved for the protocol.
fn main() {
	mut server := new_vlang_server() or {
		eprintln('${server_name}: failed to build server: ${err.msg()}')
		exit(1)
	}
	server.serve_stdio() or {
		eprintln('${server_name}: ${err.msg()}')
		exit(1)
	}
}
