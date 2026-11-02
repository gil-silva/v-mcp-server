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
]
for line in session {
	p.stdin_write(line + '\n')
}

// give the server a moment to answer initialization + tools/list + the call,
// polling with the NON-blocking read (stdout_slurp waits for server EOF).
mut out := ''
deadline := time.now().add(20 * time.second)
for time.now() < deadline && out.count('\n') < 3 {
	time.sleep(100 * time.millisecond)
	out += p.stdout_read()
}
p.signal_term()
p.close()

println(out.replace('\n', '\n--- '))

checks := ['"id":1', '"protocolVersion"', '"v_build"', '"v_symbols"', '"v_repo_brief"', '"v_affected"',
	'"isError":false', 'server_name']
mut ok := true
for c in checks {
	if !out.contains(c) {
		eprintln('✗ missing: ${c}')
		ok = false
	}
}

// Schema-validation guard: every tool must advertise the `path` property in
// its inputSchema. Clients validate arguments against these schemas, so a
// tool whose schema has no properties (the mcp module default) silently
// receives no arguments. The eight tools share one schema const, so the
// number of "name":"v_ entries must match the number of path properties.
n_tools := out.count('"name":"v_')
n_props := out.count('"properties":{"path":{')
if n_tools == 0 || n_props != n_tools {
	eprintln('✗ inputSchema: ${n_props}/${n_tools} tools declare the path property')
	ok = false
}
println(if ok { '✓ smoke passed' } else { '✗ smoke FAILED' })
exit(if ok { 0 } else { 1 })
