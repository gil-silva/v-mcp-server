#!/usr/bin/env -S v

// Smoke script: build the server, then pump a full MCP session through its
// stdio pipes — the same bytes an agent would send.
// Run: v run smoke.vsh
import os
import time

build := os.exec([@VEXE, '-o', 'bin/v-mcp-server', '-no-parallel', @VMODROOT])
if build.exit_code != 0 {
	eprintln('build failed:\n${build.output}')
	exit(1)
}
println('✓ built bin/v-mcp-server')

mut p := os.new_process('bin/v-mcp-server')
p.set_redirect_stdio()
p.run()

session := [
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke","version":"0.0.1"}}}',
	'{"jsonrpc":"2.0","method":"notifications/initialized"}',
	'{"jsonrpc":"2.0","id":2,"method":"tools/list"}',
	'{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"v_symbols","arguments":{"path":"${@VMODROOT}/main.v"}}}',
	'{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"v_server_info"}}',
]
for line in session {
	p.stdin_write(line + '\n')
}

// give the server a moment to answer initialization + tools/list + the call,
// polling with the NON-blocking read (stdout_slurp waits for server EOF).
mut out := ''
deadline := time.now().add(20 * time.second)
for time.now() < deadline && out.count('\n') < 4 {
	time.sleep(100 * time.millisecond)
	out += p.stdout_read()
}
p.signal_term()
p.close()

println(out.replace('\n', '\n--- '))

checks := ['"id":1', '"protocolVersion"', '"v_build"', '"v_symbols"', '"v_repo_brief"', '"v_affected"',
	'"v_run"', '"v_errors"', '"v_uses"', '"v_fmt"', '"v_doc"', '"v_server_info"', '"v_gate"', '"id":4',
	'built at:', '"isError":false', 'server_name']
mut ok := true
for c in checks {
	if !out.contains(c) {
		eprintln('✗ missing: ${c}')
		ok = false
	}
}

// Schema-validation guard: every tool that takes arguments must advertise a
// non-empty properties map in its inputSchema. Clients validate arguments
// against these schemas, so a tool whose schema has no properties (the mcp
// module default) silently receives no arguments. Almost every tool requires
// `path` (the shared const covers the path-only ones; the rest declare their
// own consts with `path` first); the projectless v_scratch is the exception,
// requiring `code`. The "name":"v_ entry count (minus the no-argument
// v_server_info) must equal the combined first-property count.
n_tools := out.count('"name":"v_') - out.count('"name":"v_server_info"')
n_props := out.count('"properties":{"path":{') + out.count('"properties":{"code":{')
if n_tools == 0 || n_props != n_tools {
	eprintln('✗ inputSchema: ${n_props}/${n_tools} tools declare their first property')
	ok = false
}
println(if ok { '✓ smoke passed' } else { '✗ smoke FAILED' })
exit(if ok { 0 } else { 1 })
