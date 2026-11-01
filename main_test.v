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
	assert names.contains('v_fmt_check'), names.str()
	assert names.contains('v_vet'), names.str()
	assert names.contains('v_ast'), names.str()
	assert names.contains('v_symbols'), names.str()
	assert names.contains('v_deps'), names.str()
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
