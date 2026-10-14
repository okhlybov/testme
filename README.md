# testme - a Tcl testing pico framework

Testme is an agentic-ready, high-performance testing framework for the [Tcl](https://www.tcl-lang.org/) language (compatible with Tcl 8.6+ and Tcl 9.0+).

## Features

- **Parallel Unit Execution**: High-throughput execution across multi-core systems using native OS thread pools (`Thread` package).
- **TAP 14 & TAP 13 Compliance**: Streams real-time [TAP](https://testanything.org/) 14 results as tests complete, with strict ascending TAP 13 fallback.
- **Hierarchical Subtests**: Emits standard indented TAP 14 subtests for discovered sub-suites and in-suite `subtest` blocks under `-n` / `--nested`.
- **Unit Tagging & Filtering**: Granular test selection via command-line tag inclusions (`+tag` / `tag`) and exclusions (`-tag`).
- **Lexical Scoping with `testme::with`**: Scoped tag and parameter accumulation across nested blocks at both suite and unit levels.
- **Strict Execution Containment**: Units run in isolated interpreter threads with private `::env` environments; unsafe calls like `exit` and `cd` are intercepted and reported as failures without destabilizing the runner.
- **Output Channel Capture**: `stdout` and `stderr` channels are buffered per unit, preserving a clean TAP stream on standard output.
- **Inline & Staged Execution Modes**: Explicit separation between `-origin` (read-only source directory where suite fixtures reside) and `-stage` (destination directory where files are copied or created).
- **Extensible Companions**: Automatic module resolution for companion libraries in `extra/` (such as `buildme` for filesystem sandboxing and shell execution).

---

## Prerequisites

- **Tcl 8.6+** or **Tcl 9.0+**
- **Thread package** (standard in active Tcl installations)
- *(Optional)* POSIX shell environment for the included [`tapview`](https://gitlab.com/esr/tapview) viewer, or Tcl for the pure-Tcl `extra/tapme-0.tm` consumer.

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

Run tests and format results with the included `tapview` consumer:

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
| `-n`, `--nested` | Emits hierarchical TAP 14 indented subtests (for discovered sub-suites and in-suite subtests). Off by default; disabled in TAP 13 mode. |
| `-s`, `--serial` | Runs units sequentially without a thread pool (disabling `tpool`). Degrades to serial mode automatically if the `Thread` package is not available. |
| `-v`, `--verbose` | Dumps captured `stdout` and `stderr` for failed units to standard error. |
| `-F`, `--full-dump` | Dumps captured output for succeeded units as well (useful for diagnostic inspection). |
| `-K`, `--keep` | Retains temporary directories and dumps per-unit channel log files (`<id>-<name>-<channel>.out`). |
| `-e`, `--bailout` | Aborts execution on the first failure or suite error, draining the pool and issuing a `Bail out!`. |
| `-q`, `--quiet` | Suppresses all standard output and summary messages; reports status strictly via process exit code. |
| `-T`, `--staging` | Allocates and manages a temporary staging directory in `$TMPDIR` for the test run. |
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
1. **Toplevel Phase**: The script sets up the worker thread pool and execution environment.
2. **Suite Discovery**: The suite script is executed inside an isolated interpreter box.
3. **Subdirectory Descent**: Once the suite script finishes submitting units, `testme` searches immediate subdirectories for scripts matching the suite name (or the pattern set via `-S` / `--source`).
4. **Umbrella Guard**: Any file sourced by a suite during discovery is recorded in an umbrella trail and will not be re-executed, preventing duplicate runs and breaking symlink cycles.

During suite execution, the current working directory is temporarily switched to the suite script's directory, ensuring relative file operations resolve locally.

### Subtests & Hierarchical Nesting

By default, `testme` flattens all units across discovered suites into a single continuous sequence (`1..N`), streaming test points in real time as workers complete.

When the `-n` / `--nested` flag is passed in TAP 14 mode, `testme` emits standard hierarchical [TAP 14 Subtests](https://testanything.org/tap-version-14-specification.html):
- **Discovered Sub-Suites**: Each subdirectory discovered during descent automatically forms an indented subtest block under the parent suite.
- **Programmatic In-Suite Subtests**: Suites can group child units using the `subtest` command (or `unit -subtest 1`):

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
unit -name "user-auth" -tags {auth database} -timeout 5 {
  set origin [unit -origin]
  set stage  [unit -stage]
  # test logic
}
```

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

Units execute in independent worker threads:
- **`exit` Containment**: `exit` is trapped; calling `exit` inside unit code fails that specific unit without stopping the test suite.
- **`cd` Prevention**: Working directory modifications via `cd` are forbidden inside unit interpreters to prevent multithreaded race conditions. Use staging directories or `buildme::sandbox` instead.
- **`::env` Isolation**: Each unit runs with a private copy of the environment table; mutations do not leak to other worker threads.

---

## Companion Modules

Companion packages reside in `extra/` and are automatically discovered by `testme` without requiring extra `tcl::tm::path` configuration.

### `buildme` - Sandbox & Shell Execution

The `buildme` package facilitates filesystem staging and shell execution from within unit bodies:

```tcl
unit -name "compile-project" {
  package require buildme

  buildme::sandbox {
    # Creates an isolated temporary directory seeded from [unit -origin]
    # and sets the sandbox directory as active
    buildme::shell "make clean && make"
  }
}
```

- **`buildme::sandbox { ... }`**:
  - Allocates an isolated scratch directory.
  - Automatically copies fixture files from `[unit -origin]` (or the parent sandbox if nested).
  - Ensures staged files and directories are writable (even when the source suite is read-only).
  - Evaluates the enclosed code with `buildme::shell` targeted to the sandbox.
  - Recursively removes the sandbox on completion (unless `-K` is specified). On Windows, locked files that cannot be immediately deleted are handed off to a background watchdog process.
- **`buildme::shell $cmd`**:
  - Executes shell commands within the active sandbox (or `[unit -stage]`).
  - Automatically selects `$SHELL` (or `cmd.exe` on Windows).
  - Handles paths containing spaces cleanly across platforms.

### `tapme` - TAP Stream Processor

`extra/tapme-0.tm` provides an internal Tcl TAP parser and reporter capable of consuming and formatting TAP streams from pipelines.

---

## License

Available under the MIT / BSD-style license terms of the project.

**Happy testing & have fun!**

Oleg A. Khlybov <fougas@mail.ru>
