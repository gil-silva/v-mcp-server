// Integration + unit tests for v-mcp-server.
//
// The end-to-end test compiles this repository, then drives the compiled
// stdio server with the official vlib/mcp *client* (connect_stdio →
// initialize → tools/list → tools/call). It is the same contract an agent
// session exercises, without any agent in the loop.
module main

import mcp
import json2
import os

fn compile_server() string {
	bin := os.join_path(os.temp_dir(), 'v-mcp-server-test-${os.getpid()}')
	res := os.exec([@VEXE, '-o', bin, '-no-parallel', @VMODROOT])
	if res.exit_code != 0 {
		panic('server failed to compile:\n${res.output}')
	}
	return bin
}

// tools_list_client is the client-side result type of `tools/list`.
struct ToolsListResult {
pub:
	tools []mcp.Tool
}

// call_tool_params is the client-side params type of `tools/call`.
struct CallToolParams {
	name      string
	arguments map[string]json2.Any
}

// symbols_result mirrors a tools/call → v_symbols text result.
struct CallToolResult {
pub:
	content  string @[raw]
	is_error bool   @[json: isError]
}

fn test_compile_and_handshake() {
	bin := compile_server()
	defer {
		os.rm(bin) or {}
	}

	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}

	init := client.initialize() or { panic('initialize: ${err.msg()}') }
	assert init.protocol_version.len > 0, init.protocol_version
	assert init.server_info.name == 'v-mcp-server'

	tools := client.request[Empty_tool_params, ToolsListResult]('tools/list',
		Empty_tool_params{}) or { panic('tools/list: ${err.msg()}') }
	names := tools.tools.map(it.name)
	assert names.contains('v_build'), names.str()
	assert names.contains('v_test'), names.str()
	assert names.contains('v_run'), names.str()
	assert names.contains('v_errors'), names.str()
	assert names.contains('v_fmt_check'), names.str()
	assert names.contains('v_vet'), names.str()
	assert names.contains('v_ast'), names.str()
	assert names.contains('v_symbols'), names.str()
	assert names.contains('v_deps'), names.str()
	assert names.contains('v_repo_brief'), names.str()
}

fn test_v_repo_brief_call_round_trip() {
	bin := compile_server()
	defer {
		os.rm(bin) or {}
	}
	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}
	client.initialize()!

	// brief this repository itself
	res := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_repo_brief'
			arguments: {
				'path': json2.Any(@VMODROOT)
			}
		}) or { panic('tools/call: ${err.msg()}') }
	assert !res.is_error, res.content
	assert res.content.contains('vrepo brief — '), res.content
	assert res.content.contains('module: vmcpserver 0.3.0 [MIT]'), res.content
	assert res.content.contains('entry points: main.v'), res.content
}

struct Empty_tool_params {}

fn test_v_symbols_call_round_trip() {
	bin := compile_server()
	defer {
		os.rm(bin) or {}
	}

	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}
	client.initialize()!

	// point the tool at this repository's own main.v
	res := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_symbols'
			arguments: {
				'path': json2.Any('${@VMODROOT}/main.v')
			}
		}) or { panic('tools/call: ${err.msg()}') }
	assert !res.is_error, res.content
	assert res.content.contains('v_symbols'), res.content
	assert res.content.contains('server_name'), res.content
}

fn test_symbols_from_file_outline() {
	syms := symbols_from_file(os.join_path(@VMODROOT, 'main.v'))
	assert syms.len > 10, '${syms.len} symbols'
	assert syms[0].kind != '', 'kinds are set'
	names := syms.map(it.name)
	assert names.contains('v_build_tool')
	assert names.contains('symbols_from_file')
	assert names.contains('new_vlang_server')
}

fn test_truncate_marks_oversized_output() {
	assert truncate('short') == 'short'
	big := 'x'.repeat(200_000)
	t := truncate(big)
	assert t.len < output_byte_limit + 200, 'truncation applied'
	assert t.contains('[truncated'), 'marker present'
}

fn test_parse_diagnostics_extracts_one_diagnostic() {
	sample := 'err_probe.v:2:2: error: unexpected name `this`\n' +
		'    1 | fn main() {\n' +
		'    2 |     this does not compile\n' +
		'      |     ~~~~\n' +
		'    3 | }\n'
	d := parse_diagnostics(sample)
	assert d.len == 1, 'one diagnostic, got ${d.len}'
	assert d[0].file == 'err_probe.v', d[0].file
	assert d[0].line == 2, 'line'
	assert d[0].col == 2, 'col'
	assert d[0].kind == 'error', d[0].kind
	assert d[0].message == 'unexpected name `this`', d[0].message
}

fn test_parse_diagnostics_skips_noise_and_dedupes() {
	sample := 'Compiler output from the default V compiler:\n' +
		'main.v:16:1: builder error: cannot import module "gil_silva.x" (not found)\n' +
		'   15 | import gil_silva.x\n' +
		'info: not a diagnostic header\n' +
		'warn_probe.v:2:6: warning: unused variable: `x`\n' +
		'warn_probe.v:2:6: warning: unused variable: `x`\n'
	d := parse_diagnostics(sample)
	assert d.len == 2, 'builder error + one warning, got ${d.len}'
	assert d[0].kind == 'error', d[0].kind
	assert d[0].message == 'cannot import module "gil_silva.x" (not found)', d[0].message
	assert d[1].kind == 'warning', d[1].kind
	assert d[1].col == 6, 'col'
}

fn test_v_run_and_v_errors_round_trips() {
	bin := compile_server()
	defer {
		os.rm(bin) or {}
	}
	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}
	client.initialize()!

	// v_run: tiny program printing its last argv — asserts the args plumbing
	good := os.join_path(os.temp_dir(), 'v_run_probe_${os.getpid()}.v')
	os.write_file(good, 'fn main() {\n\tprintln("run-ok")\n}\n')!
	defer {
		os.rm(good) or {}
	}
	res := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_run'
			arguments: {
				'path': json2.Any(good)
				'args': json2.Any(['arg1', 'last-arg'])
			}
		}) or { panic('tools/call v_run: ${err.msg()}') }
	assert !res.is_error, res.content
	assert res.content.contains('run-ok'), res.content

	// v_run on a compile-broken file: error result carrying the diagnostics
	bad := os.join_path(os.temp_dir(), 'v_run_bad_${os.getpid()}.v')
	os.write_file(bad, 'fn main() {\n\tthis does not compile\n}\n')!
	defer {
		os.rm(bad) or {}
	}
	res2 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_run'
			arguments: {
				'path': json2.Any(bad)
			}
		}) or { panic('tools/call v_run bad: ${err.msg()}') }
	assert res2.is_error, res2.content
	assert res2.content.contains('v_run build failed'), res2.content

	// v_errors on the same broken file: structured JSON diagnostics
	res3 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_errors'
			arguments: {
				'path': json2.Any(bad)
			}
		}) or { panic('tools/call v_errors: ${err.msg()}') }
	assert !res3.is_error, res3.content
	// content is JSON-wrapped, so inner quotes appear escaped
	assert res3.content.contains('\\"kind\\":\\"error\\"'), res3.content
	assert res3.content.contains('\\"line\\":2'), res3.content
}
