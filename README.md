# testme - a testing pico framework for Tcl
# https://github.com/okhlybov/testme

Testme is a compact testing framework for the [Tcl](https://www.tcl-lang.org/) language (compatible with Tcl 8.6+ and Tcl 9.0+) built around three ideas: every unit runs in a pristine interpreter of its own, suites are discovered recursively, and the reported [TAP](https://testanything.org/) stream is guarded so unit and suite output cannot corrupt it.

## Features

- **Parallel unit execution**: Units run across native OS thread pools with per-unit interpreter isolation; `-s` degrades to serial execution when threads are unavailable.
- **TAP 14 & TAP 13 compliance**: Streams real-time TAP 14 results as tests complete, with strict ascending TAP 13 fallback; test point descriptions escape `\` and `#`, so arbitrary unit names cannot forge directives.
- **Hierarchical subtests**: Emits standard indented TAP 14 subtests for discovered sub-suites and in-suite `subtest` blocks under `-n` / `--nested`.
- **Unit tagging & filtering**: Granular test selection via command-line tag inclusions (`+tag` / `tag`) and exclusions (`-tag`).
- **Lexical scoping with `testme::with`**: Scoped tag and parameter accumulation across nested blocks at both suite and unit levels.
- **Strict execution containment**: Units run in isolated interpreter threads with private `::env` environments; unsafe calls like `exit` and `cd` are intercepted and reported as failures without destabilizing the runner.
- **Unit timeouts**: `-timeout N` (or a run-wide `--timeout=N` default) stops runaway unit code with `interp limit` and reports `timed out after N s`.
- **Output channel capture**: Unit writes to `stdout` / `stderr` (`puts`, `chan puts`) are buffered per unit, preserving a clean TAP stream; the I/O escapes the basic capture cannot see (`exec` stream redirections, `fcopy` onto the streams, suite stdout during discovery) are denied with a pointer to `shellme`, which captures program I/O properly.
- **Inline & staged execution modes**: Explicit separation between `-origin` (read-only source directory where suite fixtures reside) and `-stage` (destination directory where files are copied or created).

---

## Prerequisites

- **Tcl 8.6+** (with **Thread 2.8+**) or **Tcl 9.0+** (with **Thread 3.0+**)

---

## Quickstart

Run a test suite:

```shell
tclsh test/test.tcl
```

Run tests and dump captured unit output for failures to `stderr`:

```shell
tclsh test/test.tcl -v
```

Run tests and format results with the included [`tapview`](https://gitlab.com/esr/tapview) consumer:

```shell
tclsh test/test.tcl | sh tapview
```

Run tests and format with the companion `tapme` consumer:

```shell
tclsh test/test.tcl | tclsh extra/tapme-0.tm
```

Separate TAP stream and error logs:

```shell
tclsh test/test.tcl -v 2> testme.log | sh tapview
```

View command-line options:

```shell
tclsh test/test.tcl -h
```

---

## Command Line Usage

```
usage: tclsh suite.tcl [options] [--] [+tag ...] [-tag ...] [tag ...]
```

### Options & Flags

| Flag / Option | Description |
| :--- | :--- |
| `-j=`, `--jobs=` | Maximum number of parallel worker threads. Defaults to detected system CPU cores. |
| `-S=`, `--source=` | Suite script filename to discover during subdirectory descent (defaults to script name of `$::argv0`). |
| `--tap=` | TAP protocol dialect: `14` (default, streamed out-of-order completion) or `13` (strictly ordered ascending indices). |
| `--timeout=` | Default unit timeout in seconds (`0` = none). Units carrying their own `-timeout` override it. Fractional values are allowed. |
| `-n`, `--nested` | Emits hierarchical TAP 14 indented subtests (for discovered sub-suites and in-suite subtests). Off by default; disabled in TAP 13 mode. |
| `-s`, `--serial` | Runs units sequentially without a thread pool (disabling `tpool`). Degrades to serial mode automatically if the `Thread` package is not available. |
| `-v`, `--verbose` | Dumps captured `stdout` and `stderr` for failed units to standard error. |
| `-F`, `--full-dump` | Dumps captured output for succeeded units as well (useful for diagnostic inspection). |
| `-K`, `--keep` | Retains temporary directories and dumps per-unit channel log files (`<id>-<name>-<channel>.out`). |
| `-e`, `--bailout` | Aborts execution on the first failure or suite error, draining the pool and issuing a `Bail out!`. |
| `-q`, `--quiet` | Suppresses all standard output and summary messages; reports status strictly via process exit code. |
| `-T`, `--staging` | Allocates and manages a temporary staging directory in `$TMPDIR` for the test run. Note: the staging directory is shared by all units of the run; use `shellme` units for per-unit scratch trees. |
| `-h`, `--help` | Displays usage and options help. |
| `--version` | Prints package version and exits. |

### Environment Options (`TESTME_OPTS`)

Default flags, options, and tag filters can be specified via the `TESTME_OPTS` environment variable. Its contents are parsed before the command line arguments, allowing command-line options to override any defaults set in the environment:

```bash
# Set serial execution and verbose output as defaults
export TESTME_OPTS="-s -v"

# Set parallel worker count and TAP 13 dialect
export TESTME_OPTS="-j 4 --tap=13"

# Include default tag filter
export TESTME_OPTS="+smoke"
```

Command-line flags take precedence over settings provided in `TESTME_OPTS`. For instance, running `tclsh suite.tcl -j 2` when `TESTME_OPTS="-s"` will execute with 2 worker threads.

### Tag Filters

Any positional arguments not recognized as flags are treated as tag filters:
- `tag` or `+tag`: Unit must match at least one specified inclusion tag to run.
- `-tag`: Unit bearing this tag will be skipped.
- If no inclusion tags are specified, all units (except those matching an exclusion tag) are eligible to run.

Exclusion filters start with `-`, so they must follow the `--` terminator to avoid being read as options:

```shell
tclsh suite.tcl -- -slow
```

---

## Test Suite Structure

A test suite is a standard Tcl script that requires `testme` at its preamble:

```tcl
tcl::tm::add [file normalize [file join [file dirname [info script]] ..]]
package require testme

unit -name "sample-test" -tags {fast smoke} {
  expr {1 + 1 == 2}
}
```

### Recursive Suite Discovery & Descent

When a test suite runs:
1. **Toplevel phase**: The script sets up the worker thread pool and execution environment.
2. **Suite discovery**: The suite script is executed inside an isolated interpreter box.
3. **Subdirectory descent**: Once the suite script finishes submitting units, `testme` searches immediate subdirectories for scripts matching the suite name (or the pattern set via `-S` / `--source`).
4. **Umbrella guard**: Any file sourced by a suite during discovery is recorded in an umbrella trail and will not be re-executed, preventing duplicate runs and breaking symlink cycles.

During suite execution, the current working directory is temporarily switched to the suite script's directory, ensuring relative file operations in the suite script itself resolve locally. While units run, the current directory is the directory the run was started from (all threads of a process share one working directory), so unit code must build paths from `[unit -origin]` / `[unit -stage]` instead of relative names.

### Subtests & Hierarchical Nesting

By default, `testme` flattens all units across discovered suites into a single continuous sequence (`1..N`), streaming test points in real time as workers complete.

When the `-n` / `--nested` flag is passed in TAP 14 mode, `testme` emits standard hierarchical [TAP 14 Subtests](https://testanything.org/tap-version-14-specification.html):
- **Discovered sub-suites**: Each subdirectory discovered during descent automatically forms an indented subtest block under the parent suite.
- **Programmatic in-suite subtests**: Suites can group child units using the `subtest` command (or `unit -subtest 1`):

```tcl
subtest -name "arithmetic" {
  unit -name "addition"       { expr {2 + 2 == 4} }
  unit -name "multiplication" { expr {3 * 3 == 9} }
}
```

Subtests can nest to arbitrary depth (each level adding 4 spaces of indentation). If any child unit within a subtest fails, the parent subtest test point is marked `not ok`. In flat mode (without `-n`) or under TAP 13, `subtest` blocks submit their units directly to the flat roster.

---

## Unit Definitions & Context

Test units are defined using the `unit` command (exported by `::testme` into the global namespace):

```tcl
unit ?-name string? ?-tags list? ?-skip reason? ?-todo reason? ?options? code
```

### Basic Unit

```tcl
unit {
  expr {42}
}
```
Creates an auto-named unit (`unit<id>`) that passes if the code block completes without throwing an error.

### Full-Fledged Unit

```tcl
unit -name "user-auth" -tags {auth database} -stdout "auth.log" {
  set origin [unit -origin]
  set stage  [unit -stage]
  # test logic
}
```

Core `unit` accepts minimal options: test identity (`-name`, `-tags`), runtime directives (`-skip`, `-todo`), and channel redirections (`-stdout`, `-stderr`, `-output`). Advanced execution options such as per-unit `-timeout` and sandbox staging are provided by wrappers like `shellme::unit`.

### Unit Timeouts

The run-wide CLI flag `--timeout=N` sets a default timeout in seconds for units (fractional values allowed), stopping runaway code with an interpreter time limit (`timed out after N s`). Per-unit `-timeout N` is supported via `shellme::unit`. A TODO unit that times out remains an expected failure; an invalid `-timeout` value fails the unit immediately instead of running it.

The limit stops Tcl code (busy loops, `after` waits). A unit blocked in an external program is reaped when the limit fires (its child processes are killed by the worker), but the unit itself cannot run cleanup code afterwards.

### Unit Outcomes

- **Success**: The code body completes normally, or issues `return` with code `0` / `ok`.
- **Failure**: Any uncaught error, or `return -code error "message"`.
- **Skip**: The unit skips itself at runtime using `skip "reason"`. Skipped units do not count as failures.

### The `unit` Accessor

Inside the unit code block, the `unit` command queries the unit's metadata record:
- Invoked bare (`[unit]`), it returns the full configuration dictionary.
- Invoked with keys (`[unit -key]`), it retrieves specific fields:

| Key | Description |
| :--- | :--- |
| `[unit -origin]` | Normalized path to the directory containing the source suite script. Read-only fixtures and test scripts reside here. |
| `[unit -stage]` | Destination staging directory. In inline mode, equals `-origin`. In staged mode (`-T`), points to the managed `$TMPDIR` directory. |
| `[unit -source]` | Normalized absolute path to the defining suite script file. |
| `[unit -name]` | Name assigned to the unit. |
| `[unit -id]` | Sequence ID of the unit in the test plan. |
| `[unit -tags]` | Normalized list of tags attached to the unit. |
| `[unit -cleanup]` | Boolean indicating whether temporary test files should be removed (`false` under `-K`). |
| `[unit -custom]` | Any user-specified option passed during unit submission. |

### Lexical Scoping with `testme::with`

The `testme::with` helper accumulates values into a list variable across nested blocks:

```tcl
testme::with tags {api} {
  unit -name "api-ping" -tags $tags { ping }

  testme::with tags {auth v2} {
    # tags here is: {api auth v2}
    unit -name "api-login" -tags $tags { login }
  }
}
```

`testme::with` is available both within suite definition scripts and inside unit execution bodies.

### Unit Containment & Isolation

Units execute in independent worker threads. The core runner keeps a deliberate divide: what a unit legitimately needs for assertions is **captured**; the I/O escapes that would threaten the TAP stream are **denied** with a pointer to `shellme`, never silently contained.

- **`exit` containment**: `exit` is trapped; calling `exit` inside unit code fails that specific unit without stopping the test suite.
- **`cd` prevention**: Working directory modifications via `cd` are forbidden inside unit interpreters to prevent multithreaded race conditions. Use staging directories or `shellme::sandbox` instead.
- **`::env` isolation**: Each unit runs with a private copy of the environment table taken after discovery; mutations do not leak to other units — and they are also *not* passed to programs the unit starts with `exec` (children inherit the process environment of the run, not the unit's modifications). Pass values to child programs explicitly, as arguments or via `shellme::shell`.
- **Basic output capture**: Everything the unit writes to `stdout` / `stderr` through `puts` or `chan puts` is buffered per unit and reported under `-v` / `-F` / `-K`.
- **Stream deny list**: The process output streams belong to the runner's TAP report, so `exec` redirections onto them (`>@ stdout`, `2>@ stderr`, split and glued forms), `fcopy` onto them, and suite `puts` to stdout during discovery are refused with an error naming the alternative (`shellme`). Program I/O belongs to [shellme](#shellme--staging-shell--program-io), which captures it properly.
- **Failure traces**: Failure diagnostics end at the unit body boundary (`(unit "name" line N)`); the full framework-level trace is kept under `-F`.

Environment adjustments made by suite scripts *while they are being collected* do reach the units.

---

## Companion Modules

The optional companions reside in `extra/` and are discovered automatically without extra `tcl::tm::path` configuration.

### `shellme` - Staging, Shell & Program I/O

The `shellme` package is the I/O and process-testing half of the framework. Its unit specification preconfigures everything a body needs to work with files and external programs:

```tcl
package require testme
package require shellme

shellme::unit -name "compile-project" -tags {build} -timeout 120 {
  # the staging sandbox is already created and seeded from the unit origin;
  # the shell already targets it; program output is already captured
  shellme::shell {make -j}
  shellme::shell {./a.out --selftest}
}

# plain units stay untouched
unit -name "math" {expr {2 + 2 == 4}}
```

- **`shellme::unit ?options? { code }`** — submits a unit configured for file and program execution (`-name`, `-tags`, `-skip`, `-todo`, `-timeout`, `-stdout`, `-stderr`, `-output` and staging options all work), wrapping the body in:
  - a per-unit **staging sandbox** seeded from `[unit -origin]`, removed on completion (even when the unit times out, or `-K` retains it);
  - `shellme::shell` targeting the sandbox;
  - **program I/O capture**: `exec … >@ stdout` / `2>@ stderr` redirections are rerouted through temporary files and collected into the unit's output report instead of being denied.
  - Shellme-specific options: `-seed dir` (default `[unit -origin]`), `-exclude {patterns}` (default `{.git .hg .svn CVS _darcs}`), `-only {paths}` (copy just these paths), `-staging auto|none` (skip the sandbox, keep the capture).
- **`shellme::sandbox ?-seed dir? ?-exclude patterns? ?-only paths? ?--? { code }`** — the staging primitive itself, usable inside plain units; nests (a sandbox inside a sandbox seeds from the parent).
- **`shellme::shell ?-timeout seconds? ?-shell program? ?--? command`**:
  - Executes a shell command within the active sandbox (or `[unit -stage]`) and returns (and echoes to the unit channels) its combined output; a non-zero exit raises an error carrying the output.
  - Uses `/bin/sh -c` on POSIX and `%COMSPEC% /c` on Windows by default. `$SHELL` is deliberately ignored; set `SHELLME_SHELL` or pass `-shell` to override.
  - Paths are quoted safely: single-quote escaping on POSIX, `cd /d` on Windows.
  - `-timeout seconds` aborts a stuck command and kills its whole process tree (best effort: process groups under `setsid` on Linux, `taskkill /T` on Windows); the error message carries the partial output. Children of a `shellme::shell` call are also reaped when the unit itself times out.

`buildme`, the earlier name of this module, has been removed.

### `tapme` - TAP Stream Processor

`extra/tapme-0.tm` provides an internal Tcl TAP parser and reporter capable of consuming and formatting TAP streams from pipelines. It understands escaped `\#` in descriptions, tolerates hostile characters in directive reasons, and recognizes `SKIP`/`TODO` spellings like `# SKIP: reason` or `# skipped: no db`.

### `xyz` - Build Flavor Helper (example)

`extra/xyz-0.tm` is a sample companion used by the framework author's own numerics testing: it derives BLAS-flavor tags (`-xyz dto`) and descriptive names for `unit` submissions, demonstrating how custom pass-through options extend the unit record.

## Performance

Isolation is the design center, not raw trivial-unit throughput: every unit gets a fresh interpreter. Expect roughly **3 ms per trivial unit** (about 2.8 µs of which is Tcl itself — compare `tcltest` running the same trivial tests in one interpreter at ~40 µs each), amortized across workers in the parallel mode. The per-unit cost is independent of environment size.

Measured with `sh bench/run.sh 500` on 8 cores (Tcl 8.6.16, Linux): 500 trivial units — 0.47 s parallel / 1.52 s serial; with 200 extra environment variables — 0.54 s / 1.62 s (no environment-size penalty); 100 subprocess-running units — 0.16 s parallel. Run `bench/run.sh` yourself to reproduce on your hardware.

## License

BSD 3-Clause License (see [LICENSE](LICENSE)). The bundled `tapview` viewer is © Eric S. Raymond, MIT-0 (see its header).

---

**Happy testing & have fun!**

Oleg A. Khlybov <fougas@mail.ru>
