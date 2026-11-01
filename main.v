// v-mcp-server
// An MCP (Model Context Protocol) server that exposes V development tooling
// to coding agents: build diagnostics, test runs, formatting checks, vet
// warnings, AST dumps, symbol outlines and v.mod dependency inspection.
//
// Built on the official `mcp` module of the V standard library; serves
// over stdio (newline-delimited JSON-RPC), the transport used by Claude
// Code, OpenCode, Zed and friends.
module main

import mcp
import json2
import os
import time

const server_name = 'v-mcp-server'

const server_version = '0.1.0'

// output_byte_limit caps any tool output, so agents never choke on
// multi-megabyte AST dumps or test logs.
const output_byte_limit = 100_000

// PathArgs is the common `arguments` payload of the tools below:
// a path to a single .v file or a project directory.
struct PathArgs {
	path string
}

// decode_args parses a tool `arguments` JSON into T.
fn decode_args[T](arguments string) !T {
	return json2.decode[T](arguments, json2.DecoderOptions{})!
}

// run_v_tool executes a `v` subcommand and wraps its output in an MCP tool
// result. A non-zero exit code yields an error result carrying both streams.
fn run_v_tool(args []string) mcp.ToolResult {
	mut p := os.new_process(args[0])
	p.set_args(args[1..])
	p.set_redirect_stdio()
	p.run()
	p.wait()
	stdout := p.stdout_slurp()
	stderr := p.stderr_slurp()
	exit_code := p.code
	defer {
		p.close()
	}

	mut out := stdout
	if stderr.len > 0 {
		out += if out.len > 0 { '\n' } else { '' } + stderr
	}
	out = out.trim_space()
	if exit_code != 0 {
		if out.len == 0 {
			out = 'command failed with exit code ${exit_code}'
		}
		return to_error_result(out)
	}
	if out.len == 0 {
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

// ---- server wiring ----------------------------------------------------------

fn new_vlang_server() !mcp.Server {
	mut server := mcp.new_server(
		name:         server_name
		version:      server_version
		instructions: 'V development server: compile, test, format-check, vet, dump AST JSON, outline symbols, inspect v.mod. PASS ABSOLUTE PATHS.'
	)
	server.add_tool(mcp.Tool{
		name:        'v_build'
		description: 'Compile a V file or project (path) and return compiler diagnostics.'
	}, v_build_tool)!
	server.add_tool(mcp.Tool{
		name:        'v_test'
		description: 'Run `v test` on a file or project (path) and return results.'
	}, v_test_tool)!
	server.add_tool(mcp.Tool{
		name:        'v_fmt_check'
		description: 'Run `v fmt -c` (check-only) on a file or directory (path). Non-zero exit if unformatted.'
	}, v_fmt_tool)!
	server.add_tool(mcp.Tool{
		name:        'v_vet'
		description: 'Run `v vet` on a file or project (path) and return warnings.'
	}, v_vet_tool)!
	server.add_tool(mcp.Tool{
		name:        'v_ast'
		description: 'Dump the AST JSON of a V file (path) via `v ast -p`. Output capped.'
	}, v_ast_tool)!
	server.add_tool(mcp.Tool{
		name:        'v_symbols'
		description: 'List top-level symbols (fn/method/struct/interface/enum/const/type + line numbers) of a .v file (path).'
	}, v_symbols_tool)!
	server.add_tool(mcp.Tool{
		name:        'v_deps'
		description: 'Read name/version/license/dependencies from the v.mod of a project (path).'
	}, v_deps_tool)!
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
