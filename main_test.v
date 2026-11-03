// Integration + unit tests for v-mcp-server.
//
// The end-to-end tests compile this repository, then drive the compiled
// stdio server with the official vlib/mcp *client* (connect_stdio →
// initialize → tools/list → tools/call). It is the same contract an agent
// session exercises, without any agent in the loop.
module main

import crypto.sha256
import mcp
import json2
import os

// server_src_key hashes what the server binary compile actually consumes —
// every non-test .v file under @VMODROOT plus the toolchain version — into
// the binary's file name. Test edits recompile nothing (a _test.v is not
// part of the server build); a main.v edit rebuilds once.
fn server_src_key() string {
	mut rows := []string{}
	mut files := os.ls(@VMODROOT) or { [] }
	files.sort()
	for f in files {
		if !f.ends_with('.v') || f.ends_with('_test.v') {
			continue
		}
		src := os.read_file(os.join_path(@VMODROOT, f)) or { continue }
		rows << '${f}\x1f${sha256.sum(src.bytes()).hex()[..16]}'
	}
	rows << 'toolchain\x1f${toolchain_stamp()}'
	return sha256.sum(rows.join('\n').bytes()).hex()[..12]
}

// compile_server compiles this repository's server binary and returns its
// absolute path. The name is content-keyed (server_src_key), so every E2E
// fn of one run — all of it executing in a single test process — and every
// rerun on unchanged sources reuses one binary: the compile happens once
// per source state instead of once per fn, which is what keeps the suite
// from paying ten times the same ~10 s of checker work. The artifact stays
// in the temp dir on purpose (a shared bin deleted after one fn would
// vanish underneath the rest of the run).
fn compile_server() string {
	bin := os.join_path(os.temp_dir(), 'v-mcp-server-test-${server_src_key()}')
	if os.is_file(bin) {
		return bin
	}
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
	assert names.contains('v_uses'), names.str()
	assert names.contains('v_read'), names.str()
	assert names.contains('v_where'), names.str()
	assert names.contains('v_scratch'), names.str()
}

fn test_compile_server_reuses_bin() {
	// same source state → one binary for the whole run: this is what keeps
	// the suite from compiling the server once per E2E fn
	a := compile_server()
	b := compile_server()
	assert a == b, '${a} vs ${b}'
	assert os.is_file(a), a
}

fn test_v_repo_brief_call_round_trip() {
	bin := compile_server()
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
	assert res.content.contains('module: vmcpserver 0.8.0 [MIT]'), res.content
	assert res.content.contains('entry points: main.v'), res.content
}

struct Empty_tool_params {}

fn test_v_symbols_call_round_trip() {
	bin := compile_server()

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

fn test_diagnostics_body_limit_shapes() {
	diags := [
		Diagnostic{ file: 'a.v', line: 1, col: 1, kind: 'error', message: 'm1' },
		Diagnostic{ file: 'b.v', line: 2, col: 3, kind: 'warning', message: 'm2' },
	]
	// no cap (limit 0) or a cap at the exact count: the plain array, unchanged
	assert diagnostics_body(diags, 0) == json2.encode(diags)
	assert diagnostics_body(diags, 2) == json2.encode(diags)
	// a cap below the count: rows + totals object, second row cut off
	body := diagnostics_body(diags, 1)
	assert body.contains('"rows":[{"file":"a.v"'), body
	assert !body.contains('"b.v"'), body
	assert body.contains('"total":2'), body
	assert body.contains('"truncated":true'), body
}

// decode_diags_or_panic decodes a plain []Diagnostic tool body, naming the
// body when the shape does not fit.
fn decode_diags_or_panic(content string) []Diagnostic {
	return json2.decode[[]Diagnostic](content) or {
		panic('decode diagnostics: ${err.msg()}: ${content}')
	}
}

// tool_text strips the first text item out of an MCP tool-result content
// array (the harness captures the raw `content` field, whose array wrapper
// is not the server's inner text).
fn tool_text(content string) string {
	items := json2.decode[[]json2.Any](content) or { return content }
	first := items[0]
	text := first.as_map()['text'] or { return content }
	return text.str()
}

// the cache identity of a *_test.v target moves with its module siblings:
// `v` pulls them into the compile beside the test, so a key on the test
// file alone replayed stale records (v_errors answered [] on a broken
// module and replayed failures after the sibling was fixed). A plain file
// target keeps keying by itself — it compiles alone.
fn test_build_cache_key_moves_with_test_module_siblings() {
	dir := os.join_path(os.temp_dir(), 'vmsd_key_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'v.mod'),
		"Module { name: 'sibs' description: 'probe' version: '0.1.0' license: 'MIT' dependencies: [] }")!
	os.write_file(os.join_path(dir, 'lib.v'), 'module sibs\n\nfn sib() int {\n\treturn 1\n}\n')!
	os.write_file(os.join_path(dir, 'lib_test.v'), 'module sibs\n\nfn test_sib() {\n\tassert sib() == 1\n}\n')!
	before := build_cache_key(os.join_path(dir, 'lib_test.v'), [])
	assert before != '', before
	os.write_file(os.join_path(dir, 'lib.v'), 'module sibs\n\nfn sib() int {\n\treturn 2\n}\n')!
	after := build_cache_key(os.join_path(dir, 'lib_test.v'), [])
	assert before != after, '${before} vs ${after}'
	// the plain neighbor keys by itself: lib_test.v edits stay out of its key
	plain_before := build_cache_key(os.join_path(dir, 'lib.v'), [])
	os.write_file(os.join_path(dir, 'lib_test.v'), 'module sibs\n\nfn test_sib() {\n\tassert sib() == 3\n}\n')!
	plain_after := build_cache_key(os.join_path(dir, 'lib.v'), [])
	assert plain_before == plain_after, '${plain_before} vs ${plain_after}'
}

// v_errors on a test file tracks the module state rather than the last
// record's truth: a broken sibling surfaces, a fixed sibling clears.
fn test_v_errors_tracks_module_state_on_test_files() {
	bin := compile_server()
	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}
	client.initialize()!

	dir := os.join_path(os.temp_dir(), 'vmsd_state_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'v.mod'),
		"Module { name: 'sibstate' description: 'probe' version: '0.1.0' license: 'MIT' dependencies: [] }")!
	good := 'module sibstate\n\nfn sib() int {\n\treturn 1\n}\n'
	bad := 'module sibstate\n\nfn sib() int {\n\treturn \n}\n'
	lib := os.join_path(dir, 'lib.v')
	test_target := os.join_path(dir, 'lib_test.v')
	os.write_file(lib, good)!
	os.write_file(test_target, 'module sibstate\n\nfn test_sib() {\n\tassert sib() == 1\n}\n')!

	clean := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_errors'
			arguments: {
				'path': json2.Any(test_target)
			}
		}) or { panic('tools/call v_errors clean: ${err.msg()}') }
	assert !clean.is_error, clean.content
	assert decode_diags_or_panic(tool_text(clean.content)).len == 0, tool_text(clean.content)

	os.write_file(lib, bad)!
	broken := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_errors'
			arguments: {
				'path': json2.Any(test_target)
			}
		}) or { panic('tools/call v_errors broken: ${err.msg()}') }
	assert !broken.is_error, broken.content
	rows := decode_diags_or_panic(tool_text(broken.content))
	assert rows.len > 0, tool_text(broken.content)
	assert rows.any(it.file.contains('lib.v')), tool_text(broken.content)

	os.write_file(lib, good)!
	fixed := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_errors'
			arguments: {
				'path': json2.Any(test_target)
			}
		}) or { panic('tools/call v_errors fixed: ${err.msg()}') }
	assert !fixed.is_error, fixed.content
	assert decode_diags_or_panic(tool_text(fixed.content)).len == 0, tool_text(fixed.content)
}

fn test_v_run_and_v_errors_round_trips() {
	bin := compile_server()
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
	// streams arrive labeled (stdout documented before stderr)
	assert res.content.contains('program stdout:'), res.content

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

	// labeled streams: both sections, stdout documented first
	streams := os.join_path(os.temp_dir(), 'v_run_streams_${os.getpid()}.v')
	os.write_file(streams, 'fn main() {\n\tprintln("to-stdout")\n\teprintln("to-stderr")\n}\n')!
	defer {
		os.rm(streams) or {}
	}
	res4 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_run'
			arguments: {
				'path': json2.Any(streams)
			}
		}) or { panic('tools/call v_run streams: ${err.msg()}') }
	assert !res4.is_error, res4.content
	// content is JSON-wrapped: the newline between label and payload is escaped
	assert res4.content.contains('program stdout:\\nto-stdout'), res4.content
	assert res4.content.contains('program stderr:\\nto-stderr'), res4.content
	// string.index is ?int; unwrap before comparing positions
	sopt := res4.content.index('program stdout:') or { -1 }
	sept := res4.content.index('program stderr:') or { -1 }
	assert sopt < sept, res4.content

	// stdin: a program that reads until EOF gets the payload and terminates
	// only on EOF — so a green call here proves both piping and the EOF
	stdin := os.join_path(os.temp_dir(), 'v_run_stdin_${os.getpid()}.v')
	os.write_file(stdin, "import os\n\nfn main() {\n\tmut all := ''\n\tfor {\n\t\tline := os.get_raw_line()\n\t\tif line.len == 0 {\n\t\t\tbreak\n\t\t}\n\t\tall += line\n\t}\n\tprint(all)\n}\n")!
	defer {
		os.rm(stdin) or {}
	}
	res5 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_run'
			arguments: {
				'path':  json2.Any(stdin)
				'stdin': json2.Any('ping\npong\n')
			}
		}) or { panic('tools/call v_run stdin: ${err.msg()}') }
	assert !res5.is_error, res5.content
	// content is JSON-wrapped: the newlines arrive escaped inside the cell
	assert res5.content.contains('program stdout:\\nping\\npong'), res5.content
}

fn test_v_errors_limit_round_trip() {
	bin := compile_server()
	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}
	client.initialize()!

	// a deliberately double-broken file: the uncapped call fixes the total
	// (and warms the cache the capped call then hits)
	broken := os.join_path(os.temp_dir(), 'v_errors_limit_${os.getpid()}.v')
	os.write_file(broken, 'fn main() {\n\tthis does not compile\n\tnot even this\n}\n')!
	defer {
		os.rm(broken) or {}
	}
	res_all := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_errors'
			arguments: {
				'path': json2.Any(broken)
			}
		}) or { panic('tools/call v_errors: ${err.msg()}') }
	assert !res_all.is_error, res_all.content
	rows := json2.decode[[]Diagnostic](res_all.content) or {
		panic('decode uncapped: ${err.msg()}: ${res_all.content}')
	}
	assert rows.len >= 1, res_all.content

	res_cap := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_errors'
			arguments: {
				'path':  json2.Any(broken)
				'limit': json2.Any(1)
			}
		}) or { panic('tools/call v_errors limit: ${err.msg()}') }
	assert !res_cap.is_error, res_cap.content
	if rows.len == 1 {
		// exactly one diagnostic in total: the cap cannot trigger, the
		// plain array shape survives
		assert res_cap.content == res_all.content, res_cap.content
		return
	}
	tr := json2.decode[TruncatedDiags](res_cap.content) or {
		panic('decode capped: ${err.msg()}: ${res_cap.content}')
	}
	assert tr.truncated, res_cap.content
	assert tr.rows.len == 1, res_cap.content
	assert tr.total == rows.len, res_cap.content
}

fn test_strip_ansi_drops_color_codes() {
	colored := '\x1b[36m@@ -1,2 +1,2 @@\x1b[0m\x1b[31m-fn main(){\x1b[0m\n\x1b[32m+fn main() {\x1b[0m\n'
	assert strip_ansi(colored) == '@@ -1,2 +1,2 @@-fn main(){\n+fn main() {\n', strip_ansi(colored)
	assert strip_ansi('plain text 123') == 'plain text 123'
	// truncated escapes (no final letter) are not sequences: copied
	// verbatim, never a panic on a string ending mid-sequence
	assert strip_ansi('\x1b') == '\x1b'
	assert strip_ansi('\x1b[') == '\x1b['
	assert strip_ansi('\x1b[31') == '\x1b[31'
	assert strip_ansi('\x1b[31mOK\x1b[') == 'OK\x1b['
}

fn test_v_fmt_check_diff_round_trip() {
	bin := compile_server()
	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}
	client.initialize()!

	// two unformatted files in a temp dir: the first check lists both files
	// plus the diff hunks (ANSI-stripped); v_fmt fixes in place, and the
	// second check turns drift-free and succeeds
	dir := os.join_path(os.temp_dir(), 'v_fmt_diff_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'a.v'), 'fn main(){\n\tmut x   =1\n\tprintln(x)\n}\n')!
	os.write_file(os.join_path(dir, 'b.v'), 'fn other(){\n\tmut y   =2\n\tprintln(y)\n}\n')!

	res := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_fmt_check'
			arguments: {
				'path': json2.Any(dir)
				'diff': json2.Any(true)
			}
		}) or { panic('tools/call v_fmt_check diff: ${err.msg()}') }
	assert res.is_error, res.content
	// the file list names both files
	assert res.content.contains('a.v'), res.content
	assert res.content.contains('b.v'), res.content
	// the hunks follow, with color codes gone
	assert res.content.contains('diff:'), res.content
	assert res.content.contains('-fn main(){'), res.content
	assert res.content.contains('+fn main() {'), res.content
	assert !res.content.contains('\x1b'), res.content

	res_fix := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_fmt'
			arguments: {
				'path': json2.Any(dir)
			}
		}) or { panic('tools/call v_fmt: ${err.msg()}') }
	assert !res_fix.is_error, res_fix.content

	res_ok := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_fmt_check'
			arguments: {
				'path': json2.Any(dir)
				'diff': json2.Any(true)
			}
		}) or { panic('tools/call v_fmt_check second: ${err.msg()}') }
	assert !res_ok.is_error, res_ok.content
	assert res_ok.content.contains('ok (exit 0, no output)'), res_ok.content
}

// gate_fixture_repo creates a one-file git repo for the v_gate E2E: a
// committed unformatted test file (plus a fresh edit for the diff), all
// state deterministic before the calls run.
fn gate_fixture_repo() !string {
	dir := os.join_path(os.temp_dir(), 'v_gate_fixture_${os.getpid()}')
	os.mkdir_all(dir)!
	os.write_file(os.join_path(dir, 'partzok_test.v'),
		'module main\n\nfn test_ok() {\n\tassert true\n\ta   :=1\n}\n')!
	steps := [
		['git', 'init', '-q', dir],
		['git', '-C', dir, 'config', 'user.email', 't@t'],
		['git', '-C', dir, 'config', 'user.name', 't'],
		['git', '-C', dir, 'add', '-A'],
		['git', '-C', dir, 'commit', '-qm', 'fixture'],
	]
	for cmd in steps {
		g := os.exec(cmd)
		assert g.exit_code == 0, g.output
	}
	// the uncommitted edit: a second test fn, still unformatted — the
	// static gate then sees fmt drift on it (no nested test runs here;
	// the narrowed-run path stays covered by the parse/stats unit tests)
	os.write_file(os.join_path(dir, 'partzok_test.v'),
		'module main\n\nfn test_ok() {\n\tassert true\n\ta   :=1\n}\n\nfn test_bad() {\n\tassert false\n}\n')!
	return dir
}

fn test_v_gate_fixture_round_trip() {
	bin := compile_server()
	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}
	client.initialize()!
	dir := gate_fixture_repo()!
	defer {
		os.rmdir_all(dir) or {}
	}

	// the full gate (static sections only): fmt drift on the uncommitted edit
	res := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_gate'
			arguments: {
				'path': json2.Any(dir)
			}
		}) or { panic('tools/call v_gate: ${err.msg()}') }
	assert res.is_error, res.content
	assert res.content.contains('\\"fmt_check\\":{\\"ok\\":false'), res.content
	assert res.content.contains('\\"partzok_test.v\\"'), res.content
	assert res.content.contains('\\"affected\\":[\\"partzok_test.v\\"'), res.content
	assert res.content.contains('\\"tests_run\\":false'), res.content

	// after formatting the fixture in place: the whole gate turns green
	res_fmt := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_fmt'
			arguments: {
				'path': json2.Any(dir)
			}
		}) or { panic('tools/call v_fmt: ${err.msg()}') }
	assert !res_fmt.is_error, res_fmt.content

	res_green := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_gate'
			arguments: {
				'path': json2.Any(dir)
			}
		}) or { panic('tools/call v_gate green: ${err.msg()}') }
	assert !res_green.is_error, res_green.content
	assert res_green.content.contains('\\"ok\\":true'), res_green.content
	assert res_green.content.contains('\\"fmt_check\\":{\\"ok\\":true'), res_green.content
}

fn test_v_gate_affected_requires_git() {
	bin := compile_server()
	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}
	client.initialize()!

	// a plain temp dir (no .git): the affected step cannot run — a gate
	// failure, not a silent empty set
	dir := os.join_path(os.temp_dir(), 'v_gate_nogit_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	res := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_gate'
			arguments: {
				'path': json2.Any(dir)
			}
		}) or { panic('tools/call v_gate nogit: ${err.msg()}') }
	assert res.is_error, res.content
	assert res.content.contains('v_gate: affected set:'), res.content
}

fn test_v_gate_panic_round_trip() {
	bin := compile_server()
	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}
	client.initialize()!
	dir := gate_fixture_repo()!
	defer {
		os.rmdir_all(dir) or {}
	}
	// the working file becomes clean-formatted with a panicking second test
	// (still uncommitted vs HEAD): fmt and vet pass, the affected set is the
	// one file, and its narrowed run dies mid-suite with no FAIL row — the
	// tests section must fail the gate AND carry the raw panic text
	os.write_file(os.join_path(dir, 'partzok_test.v'),
		"module main\n\nfn test_fore() {\n\tassert true\n}\n\nfn test_boom() {\n\tpanic('kaboom')\n}\n")!
	res := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_gate'
			arguments: {
				'path':      json2.Any(dir)
				'run_tests': json2.Any(true)
			}
		}) or { panic('tools/call v_gate panic: ${err.msg()}') }
	assert res.is_error, res.content
	assert res.content.contains('\\"fmt_check\\":{\\"ok\\":true'), res.content
	assert res.content.contains('\\"affected\\":[\\"partzok_test.v\\"'), res.content
	assert res.content.contains('\\"tests_run\\":true'), res.content
	assert res.content.contains('\\"tests\\":{\\"ok\\":false'), res.content
	assert res.content.contains('test_fore'), res.content
	assert res.content.contains('kaboom'), res.content
}

fn test_v_scratch_and_timeout_round_trips() {
	bin := compile_server()
	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}
	client.initialize()!

	// a complete standalone program compiles and runs, output labeled
	// exactly like v_run (content is JSON-wrapped: newlines arrive escaped)
	res := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_scratch'
			arguments: {
				'code': json2.Any('fn main() {\n\tprintln("ping")\n\tprintln("pong")\n}\n')
			}
		}) or { panic('tools/call v_scratch: ${err.msg()}') }
	assert !res.is_error, res.content
	assert res.content.contains('program stdout:\\nping\\npong'), res.content

	// stdin rides the same temp-file wrapper v_run uses, EOF closed
	res2 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_scratch'
			arguments: {
				'code':  json2.Any("import os\n\nfn main() {\n\tmut all := ''\n\tfor {\n\t\tline := os.get_raw_line()\n\t\tif line.len == 0 {\n\t\t\tbreak\n\t\t}\n\t\tall += line\n\t}\n\tprint(all)\n}\n")
				'stdin': json2.Any('ping\npong\n')
			}
		}) or { panic('tools/call v_scratch stdin: ${err.msg()}') }
	assert !res2.is_error, res2.content
	assert res2.content.contains('program stdout:\\nping\\npong'), res2.content

	// snippets that do not compile come back labeled like v_run build
	// failures (a bare `tmp := 1` is a legit script-mode success — a
	// warning only — so the probe needs a real checker error)
	res3 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_scratch'
			arguments: {
				'code': json2.Any('println(undefined_name_xyz)\n')
			}
		}) or { panic('tools/call v_scratch failing snippet: ${err.msg()}') }
	assert res3.is_error, res3.content
	assert res3.content.contains('v_scratch build failed'), res3.content

	// the identical failing snippet is cache-keyed: the repeat call replays
	// the stored record and fails exactly the same
	res4 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_scratch'
			arguments: {
				'code': json2.Any('println(undefined_name_xyz)\n')
			}
		}) or { panic('tools/call v_scratch repeat: ${err.msg()}') }
	assert res4.is_error, res4.content
	assert res4.content == res3.content, 'cache replay kept the message: ${res4.content}'

	// v_run's timeout override: a sleeping program is killed at its own cap
	// and the label names that cap, not the server default
	probe := os.join_path(os.temp_dir(), 'v_run_timeout_probe_${os.getpid()}.v')
	os.write_file(probe, 'import time\n\nfn main() {\n\ttime.sleep(30 * time.second)\n}\n')!
	defer {
		os.rm(probe) or {}
	}
	res5 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_run'
			arguments: {
				'path':    json2.Any(probe)
				'timeout': json2.Any(2)
			}
		}) or { panic('tools/call v_run timeout: ${err.msg()}') }
	assert res5.is_error, res5.content
	assert res5.content.contains('program timed out after 2 s'), res5.content

	// out-of-range overrides are refused before anything spawns
	res6 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_run'
			arguments: {
				'path':    json2.Any(probe)
				'timeout': json2.Any(0)
			}
		}) or { panic('tools/call v_run timeout 0: ${err.msg()}') }
	assert res6.is_error, res6.content
	assert res6.content.contains('bad arguments'), res6.content
	assert res6.content.contains('timeout: 0 s must be between 1 and 1800'), res6.content

	// same cap on v_test, same refusal
	res7 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_test'
			arguments: {
				'path':    json2.Any(@VMODROOT)
				'timeout': json2.Any(5000)
			}
		}) or { panic('tools/call v_test timeout 5000: ${err.msg()}') }
	assert res7.is_error, res7.content
	assert res7.content.contains('timeout: 5000 s must be between 1 and 1800'), res7.content
}

fn test_v_uses_call_round_trip() {
	bin := compile_server()
	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}
	client.initialize()!

	// who uses run_capture? — the report shows its definition and callers
	res := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_uses'
			arguments: {
				'path':   json2.Any(@VMODROOT)
				'symbol': json2.Any('run_capture')
			}
		}) or { panic('tools/call v_uses: ${err.msg()}') }
	assert !res.is_error, res.content
	assert res.content.contains('## definitions'), res.content
	assert res.content.contains('fn run_capture'), res.content
	assert res.content.contains('## callers'), res.content

	// a missing symbol argument is a tool error, not a crash
	res2 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_uses'
			arguments: {
				'path': json2.Any(@VMODROOT)
			}
		}) or { panic('tools/call v_uses bad: ${err.msg()}') }
	assert res2.is_error, res2.content
	assert res2.content.contains('symbol'), res2.content
}

fn test_v_deps_multiline_round_trip() {
	bin := compile_server()
	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}
	client.initialize()!
	// a multiline dependencies list must stream past its first line
	dir := os.join_path(os.temp_dir(), 'v_deps_multi_${os.getpid()}')
	os.mkdir(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'v.mod'),
		"Module {\n\tname: 'devmulti'\n\tversion: '0.0.1'\n\tdependencies: [\n\t\t'https://example.com/a',\n\t\t'https://example.com/b'\n\t]\n}\n")!
	res := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_deps'
			arguments: {
				'path': json2.Any(dir)
			}
		}) or { panic('tools/call v_deps: ${err.msg()}') }
	assert !res.is_error, res.content
	assert res.content.contains('example.com/a'), res.content
	assert res.content.contains('example.com/b'), res.content
}

fn test_validate_vflags() {
	// good shapes: bare flags, and an option taking one value after it
	validate_vflags([]) or { assert false, err.msg() }
	validate_vflags(['-prod', '-g']) or { assert false, err.msg() }
	validate_vflags(['-cc', 'clang']) or { assert false, err.msg() }
	validate_vflags(['--some-flag']) or { assert false, err.msg() }
	// bad shapes: stray values without their flag, empty strings
	mut rejected := false
	validate_vflags(['clang']) or { rejected = true }
	assert rejected, 'stray value must be rejected'
	rejected = false
	validate_vflags(['a.v']) or { rejected = true }
	assert rejected, 'source path in vflags must be rejected'
	rejected = false
	validate_vflags(['-prod', 'clang', 'extra']) or { rejected = true }
	assert rejected, 'second stray value must be rejected'
	rejected = false
	validate_vflags(['-cc', 'clang', 'clang']) or { rejected = true }
	assert rejected, 'value chains must be rejected'
	rejected = false
	validate_vflags(['']) or { rejected = true }
	assert rejected, 'empty flag must be rejected'
}

fn test_resolve_timeout() {
	t_none := resolve_timeout(none)!
	assert t_none == tool_timeout_seconds, 'no override yields the server default, got ${t_none}'
	t_2 := resolve_timeout(2)!
	assert t_2 == 2, 'a plain call override passes through, got ${t_2}'
	t_max := resolve_timeout(tool_timeout_seconds_max)!
	assert t_max == tool_timeout_seconds_max, 'the max itself is accepted'
	// out of range, below and above, is refused rather than quietly adjusted
	mut rejected := false
	resolve_timeout(0) or { rejected = true }
	assert rejected, '0 must be rejected'
	rejected = false
	resolve_timeout(-3) or { rejected = true }
	assert rejected, 'negative caps must be rejected'
	rejected = false
	resolve_timeout(tool_timeout_seconds_max + 1) or { rejected = true }
	assert rejected, 'above the max must be rejected'
}

fn test_validate_filter() {
	validate_filter('*parse_fn*') or { assert false, err.msg() }
	validate_filter('test_a1-[0-9]*') or { assert false, err.msg() }
	// file filters: path separators and the comma separator are legal
	validate_filter('src/parse/parse_test.v') or { assert false, err.msg() }
	validate_filter('parse_test.v,cache_test.v') or { assert false, err.msg() }
	mut rejected := false
	validate_filter('a space') or { rejected = true }
	assert rejected, 'spaces must be rejected'
	rejected = false
	validate_filter('x;y') or { rejected = true }
	assert rejected, 'stray characters must be rejected'
	rejected = false
	validate_filter('a,b;c*d') or { rejected = true }
	assert rejected, 'stray characters must be rejected in file filters too'
}

fn test_env_test_filter_prefix() {
	// nothing asked: both inherited harness filters are cleared
	assert env_test_filter_prefix('', '') == ['-u', 'VTEST_ONLY_FN', '-u', 'VTEST_ONLY']
	// functions only: the file filter is still cleared, and -u entries come
	// before the assignments (env(1) stops parsing options at the first one)
	assert env_test_filter_prefix('*alpha*', '') == ['-u', 'VTEST_ONLY', 'VTEST_ONLY_FN=*alpha*']
	// files only: function filter still cleared
	assert env_test_filter_prefix('', 'a_test.v') == ['-u', 'VTEST_ONLY_FN', 'VTEST_ONLY=a_test.v']
}

fn test_symbol_source_slices_and_misses() {
	path := os.join_path(@VMODROOT, 'main.v')
	// the slice contains the whole fn and its doc comment, but not the next fn
	ss := symbol_source(path, 'truncate') or {
		assert false, 'symbol_source: ${err.msg()}'
		SymbolSource{}
	}
	assert ss.text.contains('fn truncate'), ss.text
	assert ss.text.contains('// truncate caps'), 'doc comment included'
	assert !ss.text.contains('fn tmp_output_path'), 'next fn must be excluded'
	assert ss.from > 0, 'line range'
	assert ss.to >= ss.from, 'line range ordering'
	// v_errors spans its comment banner; the previous fn's body stays out
	ss2 := symbol_source(path, 'v_errors_tool') or {
		assert false, 'symbol_source: ${err.msg()}'
		SymbolSource{}
	}
	assert ss2.text.contains('fn v_errors_tool'), ss2.text
	assert !ss2.text.contains('fn v_run_tool'), 'previous fn body excluded'
	// a missing symbol lists the declared candidates
	_ = symbol_source(path, 'no_such_symbol_here') or {
		assert err.msg().contains('no symbol named'), err.msg()
		SymbolSource{}
	}
}

fn test_v_where_v_read_and_argument_validation() {
	bin := compile_server()
	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}
	client.initialize()!

	// v_where: a workspace tree with two projects (one nested) and a hidden
	// third that must stay out
	ws := os.join_path(os.temp_dir(), 'v_where_ws_${os.getpid()}')
	os.rmdir_all(ws) or {}
	alpha := os.join_path(ws, 'alpha')
	os.mkdir_all(alpha)!
	os.write_file(os.join_path(alpha, 'v.mod'), "Module {\n\tname: 'projalpha'\n\tversion: '0.1.0'\n}\n")!
	beta := os.join_path(ws, 'sub', 'projbeta')
	os.mkdir_all(beta)!
	os.write_file(os.join_path(beta, 'v.mod'), "Module {\n\tname: 'projbeta'\n\tversion: '0.2.0'\n}\n")!
	os.mkdir_all(os.join_path(ws, '.hidden', 'secret'))!
	os.write_file(os.join_path(ws, '.hidden', 'secret', 'v.mod'), "Module {\n\tname: 'projhidden'\n}\n")!
	defer {
		os.rmdir_all(ws) or {}
	}
	res := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_where'
			arguments: {
				'path': json2.Any(ws)
			}
		}) or { panic('tools/call v_where: ${err.msg()}') }
	assert !res.is_error, res.content
	assert res.content.contains("name: 'projalpha'"), res.content
	assert res.content.contains(beta), res.content
	assert res.content.contains("name: 'projbeta'"), res.content
	assert !res.content.contains('projhidden'), 'hidden directories are skipped'

	// v_read: a pinpoint slice of truncate (fn + doc comment, range header)
	res2 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_read'
			arguments: {
				'path':   json2.Any('${@VMODROOT}/main.v')
				'symbol': json2.Any('truncate')
			}
		}) or { panic('tools/call v_read: ${err.msg()}') }
	assert !res2.is_error, res2.content
	assert res2.content.contains('fn truncate'), res2.content
	assert res2.content.contains('main.v:'), 'range header in ${res2.content}'
	assert res2.content.contains('agents chunk better than they download'), res2.content
	assert !res2.content.contains('fn tmp_output_path'), res2.content

	// invalid vflags only: a clear argument error, not a compile attempt
	res3 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_build'
			arguments: {
				'path':   json2.Any('${@VMODROOT}/main.v')
				'vflags': json2.Any(['stray.v'])
			}
		}) or { panic('tools/call v_build bad vflags: ${err.msg()}') }
	assert res3.is_error, res3.content
	assert res3.content.contains('bad arguments: vflags[0]'), res3.content

	// invalid only: rejected before env(1) ever sees it
	res4 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_test'
			arguments: {
				'path': json2.Any(ws)
				'only': json2.Any('x y')
			}
		}) or { panic('tools/call v_test bad only: ${err.msg()}') }
	assert res4.is_error, res4.content
	assert res4.content.contains('bad arguments'), res4.content
	assert res4.content.contains('unsupported character'), res4.content

	// the same rejection guards files: bad file filters never reach env(1)
	res5 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_test'
			arguments: {
				'path':  json2.Any(ws)
				'files': json2.Any('a b')
			}
		}) or { panic('tools/call v_test bad files: ${err.msg()}') }
	assert res5.is_error, res5.content
	assert res5.content.contains('unsupported character'), res5.content

	// v_read with a missing symbol lists what IS declared
	res6 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_read'
			arguments: {
				'path':   json2.Any('${@VMODROOT}/main.v')
				'symbol': json2.Any('no_such_symbol_here')
			}
		}) or { panic('tools/call v_read missing: ${err.msg()}') }
	assert res6.is_error, res6.content
	assert res6.content.contains('no symbol named'), res6.content

	// v_errors on a compile failure with no parseable diagnostics: the
	// summary explains and the captured text follows. v itself prints the
	// option line twice (stderr, then its output echo) — the message keeps
	// exactly those two
	res7 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_errors'
			arguments: {
				'path':   json2.Any('${@VMODROOT}/main.v')
				'vflags': json2.Any(['-this-flag-does-not-exist'])
			}
		}) or { panic('tools/call v_errors bad flag: ${err.msg()}') }
	assert res7.is_error, res7.content
	assert res7.content.contains('v_errors: command failed with exit code 1'), res7.content
	n_opts := res7.content.count('unknown option')
	assert n_opts == 2, 'compiler echo kept intact, got ${n_opts}: ${res7.content}'

	// v_affected outside a git repository: a labeled failure, nothing more
	res8 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_affected'
			arguments: {
				'path': json2.Any(ws)
			}
		}) or { panic('tools/call v_affected not a repo: ${err.msg()}') }
	assert res8.is_error, res8.content
	assert res8.content.contains('v_affected: git diff failed'), res8.content
}

fn test_parse_test_rows() {
	sample := '---- Testing... ----------------------------------------------------------------\n' +
		'running tests in: /tmp/probe/main_test.v\n' +
		'     OK    [1/2]     0.001 ms     1 assert | main.test_add_ok()\n' +
		'     FAIL  [2/2]     0.017 ms     1 assert | main.test_add_fail()\n' +
		'     Summary for running V tests in "main_test.v": 1 failed, 1 passed, 2 total.\n'
	rows := parse_test_rows(sample)
	assert rows.len == 2, '${rows.len} rows'
	assert rows[0].name == 'main.test_add_ok', rows[0].name
	assert rows[0].ok
	assert rows[0].file == '/tmp/probe/main_test.v', rows[0].file
	assert rows[0].at == '', rows[0].at
	assert rows[0].detail == '', rows[0].detail
	assert rows[1].name == 'main.test_add_fail', rows[1].name
	assert !rows[1].ok
	assert rows[1].ms > 0.01, '${rows[1].ms} ms'
	assert rows[1].at == '', rows[1].at
	// all-passing report: rows only, no detail section
	assert !test_report([rows[0]], 'raw').contains('failure detail')
	assert test_report([rows[1]], 'boom detail').contains('failure detail:\nboom detail')

	// a real `-stats` failure block: the header line and the failing
	// statement with its captured values land on the row as at/detail
	failing := 'running tests in: /tmp/probe/sum_test.v\n' +
		'/tmp/probe/sum_test.v:12: fn test_sum\n' +
		'   > assert x == y\n' +
		'     Left value (len: 1): `3`\n' +
		'    Right value (len: 1): `5`\n' +
		'\n' +
		'     FAIL  [1/1]     0.010 ms     1 assert | main.test_sum()\n'
	failed := parse_test_rows(failing)
	assert failed.len == 1, '${failed.len} rows'
	assert failed[0].at == '/tmp/probe/sum_test.v:12: fn test_sum', failed[0].at
	assert failed[0].detail.contains('assert x == y'), failed[0].detail
	assert failed[0].detail.contains('Left value'), failed[0].detail
	assert failed[0].detail.contains('Right value (len: 1): `5`'), failed[0].detail
	// the header line itself moves into `at`, not the detail
	assert !failed[0].detail.contains('fn test_sum'), failed[0].detail
}

fn test_v_test_stats_round_trip() {
	bin := compile_server()
	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}
	client.initialize()!

	// a two-file, three-test fixture: probe_test.v (one passes, one fails),
	// probe2_test.v (passes) — the same one v_affected would have listed
	dir := os.join_path(os.temp_dir(), 'v_test_stats_${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir(dir)!
	os.write_file(os.join_path(dir, 'probe_test.v'), 'fn test_alpha_ok() {\n\tassert 1 + 1 == 2\n}\n\nfn test_beta_fail() {\n\tassert 1 + 1 == 3\n}\n')!
	os.write_file(os.join_path(dir, 'probe2_test.v'), 'fn test_gamma_ok() {\n\tassert 1 + 1 == 2\n}\n')!
	defer {
		os.rmdir_all(dir) or {}
	}
	// both files are on: alpha+gamma pass, beta fails — a failing run is
	// an error result, the same contract as the plain branch and v_gate
	res := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_test'
			arguments: {
				'path':  json2.Any(dir)
				'stats': json2.Any(true)
			}
		}) or { panic('tools/call v_test: ${err.msg()}') }
	assert res.is_error, res.content
	assert res.content.contains('tests: 2/3 passed'), res.content
	assert res.content.contains('test_alpha_ok'), res.content
	assert res.content.contains('test_beta_fail'), res.content
	assert res.content.contains('failure detail:'), res.content

	// stats + only: the glob narrows the suite to one function
	res2 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_test'
			arguments: {
				'path':  json2.Any(dir)
				'only':  json2.Any('*alpha*')
				'stats': json2.Any(true)
			}
		}) or { panic('tools/call v_test only: ${err.msg()}') }
	assert !res2.is_error, res2.content
	assert res2.content.contains('tests: 1/1 passed'), res2.content
	assert res2.content.contains('test_alpha_ok'), res2.content
	assert !res2.content.contains('test_beta_fail'), res2.content

	// stats + files: the unfiltered run above was 2/3; the file filter
	// narrows the suite to probe2_test.v exactly like a v_affected-trimmed
	// rerun
	res3 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_test'
			arguments: {
				'path':  json2.Any(dir)
				'files': json2.Any('probe2_test.v')
				'stats': json2.Any(true)
			}
		}) or { panic('tools/call v_test files: ${err.msg()}') }
	assert !res3.is_error, res3.content
	assert res3.content.contains('tests: 1/1 passed'), res3.content
	assert res3.content.contains('test_gamma_ok'), res3.content
	assert !res3.content.contains('test_beta_fail'), 'filtered file excluded: ${res3.content}'
	assert !res3.content.contains('test_alpha_ok'), res3.content

	// a panic kills the runner with no FAIL row: the earlier OK row still
	// parses, and the run-level failure must surface — an error result
	// carrying the rows plus the raw panic text as the raw view
	dir2 := os.join_path(os.temp_dir(), 'v_test_panic_${os.getpid()}')
	os.rmdir_all(dir2) or {}
	os.mkdir(dir2)!
	os.write_file(os.join_path(dir2, 'boom_test.v'),
		"fn test_fore() {\n\tassert true\n}\n\nfn test_boom() {\n\tpanic('kaboom')\n}\n")!
	defer {
		os.rmdir_all(dir2) or {}
	}
	res4 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_test'
			arguments: {
				'path':  json2.Any(dir2)
				'stats': json2.Any(true)
			}
		}) or { panic('tools/call v_test panic: ${err.msg()}') }
	assert res4.is_error, res4.content
	assert res4.content.contains('tests: 1/1 passed'), res4.content
	assert res4.content.contains('raw view (the run did not finish cleanly)'), res4.content
	assert res4.content.contains('kaboom'), res4.content
}

fn test_build_cache_key_determinism_and_scope() {
	dir := os.join_path(os.temp_dir(), 'cachekey_${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir)!
	os.write_file(os.join_path(dir, 'main.v'), 'fn main() {\n\tprintln(1)\n}\n')!
	os.write_file(os.join_path(dir, 'v.mod'), "Module {\n\tname: 'cacheprobe'\n}\n")!
	defer {
		os.rmdir_all(dir) or {}
	}
	key1 := build_cache_key(dir, [])
	key2 := build_cache_key(dir, [])
	assert key1 == key2, 'same tree, same key'
	assert key1.len == 64, 'sha256 hex'
	// vflags are part of the identity
	assert build_cache_key(dir, ['-prod']) != key1
	// a source rewrite changes the key
	os.write_file(os.join_path(dir, 'main.v'), 'fn main() {\n\tprintln(2)\n}\n')!
	assert build_cache_key(dir, []) != key1
	// a single .v file hashes only itself — directory/rewrites beside it don't
	file := os.join_path(os.temp_dir(), 'cachekey_probe_${os.getpid()}.v')
	os.write_file(file, 'fn main() {\n\tprintln(3)\n}\n')!
	defer {
		os.rm(file) or {}
	}
	fkey1 := build_cache_key(file, [])
	assert fkey1.len == 64
	assert fkey1 != key1
	os.write_file(os.join_path(dir, 'main.v'), 'fn main() {\n\tprintln(4)\n}\n')!
	assert build_cache_key(file, []) == fkey1, 'file key ignores sibling content'
}

fn test_scratch_source_path() {
	a := scratch_source_path('fn main() {\n\tprintln(1)\n}\n')
	b := scratch_source_path('fn main() {\n\tprintln(1)\n}\n')
	c := scratch_source_path('fn main() {\n\tprintln(2)\n}\n')
	assert a == b, 'identical snippets are content-addressed to one file: ${a}'
	assert a != c, 'distinct snippets never share a name: ${a} vs ${c}'
	assert a.contains('v-mcp-scratch-'), 'snippets live in the per-process scratch dir: ${a}'
	assert a.ends_with('.v'), a
}

fn test_cache_save_and_load_round_trip() {
	key := '0'.repeat(64)
	rec := CachedBuild{
		ok:      true
		text:    'cached text'
		summary: ''
	}
	cache_save(key, rec, '')
	loaded := cache_load(key) or {
		assert false, 'cache_load returned none for a saved record'
		rec
	}
	assert loaded.ok
	assert loaded.text == 'cached text'
	// a record that never existed loads as none
	if miss := cache_load('f'.repeat(64)) {
		_ = miss
		assert false, 'absent key must load as none'
	}
}

fn test_v_run_warm_cache_round_trip() {
	bin := compile_server()
	mut client := mcp.connect_stdio(bin, [], mcp.ClientConfig{}) or {
		panic('connect_stdio: ${err.msg()}')
	}
	defer {
		client.close()
	}
	client.initialize()!

	prog := os.join_path(os.temp_dir(), 'cache_probe_${os.getpid()}.v')
	os.write_file(prog, 'fn main() {\n\tprintln("gamma-7")\n}\n')!
	defer {
		os.rm(prog) or {}
	}
	res1 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_run'
			arguments: {
				'path': json2.Any(prog)
			}
		}) or { panic('tools/call v_run 1: ${err.msg()}') }
	assert !res1.is_error, res1.content
	assert res1.content.contains('gamma-7'), res1.content
	// the compile is stored: record and binary exist under the key
	key := build_cache_key(prog, [])
	assert key.len == 64
	stored := cache_load(key) or {
		assert false, 'cache miss after first v_run call'
		CachedBuild{}
	}
	assert stored.ok, 'a successful v_run build is cached'
	assert os.is_file(os.join_path(cache_dir(), key, 'bin')), 'the binary is cached'
	// second call replays the stored binary — byte-identical result, no v run
	res2 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_run'
			arguments: {
				'path': json2.Any(prog)
			}
		}) or { panic('tools/call v_run 2: ${err.msg()}') }
	assert !res2.is_error, res2.content
	assert res2.content == res1.content, 'hit replays the same result'
	// rewriting the source busts the key: a fresh compile runs
	os.write_file(prog, 'fn main() {\n\tprintln("gamma-8")\n}\n')!
	res3 := client.request[CallToolParams, CallToolResult]('tools/call',
		CallToolParams{
			name:      'v_run'
			arguments: {
				'path': json2.Any(prog)
			}
		}) or { panic('tools/call v_run 3: ${err.msg()}') }
	assert !res3.is_error, res3.content
	assert res3.content.contains('gamma-8'), 'key change forces recompile'
	assert res3.content != res1.content, res3.content
}
