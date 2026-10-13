# testme internals

Audience: testme hackers and maintainers. The user-facing documentation lives in [README.md](README.md).

## The module family

| module | role |
|---|---|
| `testme-*.tm` | the harness: command line, the nesting protocol, the thread pool, TAP emission, containment |
| `clip-*.tm` | command line parser; consumed by testme and tapme |
| `tapme-*.tm` | TAP consumer: streaming parser, consistency validation, trailing summary; CLI reading stdin |
| `buildme-*.tm` | per-unit staging directories & external command execution for the unit code |

## The layer model

`testme` presents a different face to every layer it is loaded from, and once a driver is present no layer ever loads a module copy:

| layer | context | face provided |
|---|---|---|
| driver | the toplevel suite (no pre-registration) | the full machinery: command line parsing, thread pool, nested suite discovery, TAP emission, run loop |
| suite box | child interpreter created by the driver's `Import` | the `unit` & `nest` commands, aliased into the driver |
| unit code | worker interpreter created by the thread pool | the auxiliary helpers (`testme::with`) and the `context` accessor over the unit record — no driving machinery |
| bare require | none of the above (an interactive `tclsh` etc.) | a catchable error — there is no layer context to join |

## The load protocol

The driver **pre-registers itself in every child it creates** via `package ifneeded` stubs:

- `Import` plants a stub in every suite box — the face is the `unit` & `nest` commands (aliases into the driver) plus the namespace export — and threads the protocol record into the child as global variables.
- `process` plants a stub in every unit interpreter — the face is `package provide` plus the `testme::with` helper, defined on the spot — and aliases the `context` accessor over the unit record. The driver version reaches the workers through the pool's init script.
- Bare requires (no suite context) find no stub: the real module loads, the `::argv0` guard raises a catchable error.

Consequences: exactly one machinery generation exists per run; stale vendored copies are never sourced; shaping a facade means editing a stub, not the module search order.

### The protocol roster

The record every child receives is declared as data — the `fields` roster in `testme-0.1.tm`:

- `::argv0` (the child's suite source path) and `::ancestors` (the suite's ancestry — the suite source itself included, so the nesting depth is `[llength $::ancestors] - 1` wherever needed; doubling as the symlink-loop guard and serving as the layer discriminator) are computed per level in `Import`.
- Every other roster field (`bailout` — the fail-fast policy) is propagated as-is or seeded with its roster default when absent.

Adding a field takes one roster line: the propagation loop in `Import` and the adoption loop in the toplevel initialization are generic.

## The run flow

1. Command line: `clip::parse` over the supported options; the trailing arguments are the `+tag`/`-tag` filters; under `-q` the tapme package is loaded (tapme is a soft dependency).
2. The optional staging directory (`-T`) is set as `TMPDIR`; the thread pool executor is created — the initcmd installs the module paths, the driver version and the `static` worker code.
3. `Import` brings the toplevel suite into a child interpreter; its `package require testme` fires the stub, which triggers `Nest` — the depth-first nested suite lookup (`*/<suite-name>`), symlink loops broken by the ancestry record. Every discovered suite imports recursively; failed imports become **synthetic failed units** (`FailSuite`) unless `-e` re-raises.
4. The driver emits the TAP header, the plan and the skipped units (`Emit`), then drains the pool (`tpool::wait` → `Report`) and reports the synthetic results. Exit status: 0 when all passed, 1 otherwise.
5. `process` (worker side) runs each unit in a fresh interpreter: `exit` redefined to report (arguments preserved), `puts`/`skip` aliased into the capture/tally layer, the unit facade stub planted, the unit code applied via `apply`. The result record carries the return code, the reason and the captured channels.

## Containment

- `exit` in test code is a redefined throwing proc — units and suite boxes alike — so process termination attempts are reported as failures with their arguments.
- Suite processing errors become synthetic failed units; `-e` turns the first anomaly of any kind into a bail out: the queued pool jobs are cancelled (`tpool::cancel`), the in-flight units are drained silently and the process terminates only once the workers are idle, which keeps the termination deterministic (no thread finalization races, no abandoned queued work).
- Framework-level death prints the reason on stderr unconditionally (the trace stays behind `-v`), then `Bail out!` and exit 1.
- No time limits by design — wrap unattended runs in an external `timeout`.

## Output paths

- **stdout**: TAP header, plan, per-unit lines with YAML failure blocks. Suite code can still write there (the trusted layer; unit output is captured and cannot pollute the stream).
- **stderr**: `-v`/`-F` unit channel dumps, `-K` per-unit log files (`id-name-channel.out` in the staging directory or the current directory), framework diagnostics, and the `-q` verdict.
- Under `-q`: the TAP lines feed the tapme consumer instead of stdout, and the consumer's summary — or, without tapme, a driver-side one-liner — lands on stderr.

## Known residuals

- `buildme` sandbox names carry a random tail; identical draws across concurrent units of one suite share a staging directory (`file mkdir` has no exclusivity). Fix direction: name by the driver-unique unit id.
- `testme::with` is a unit-layer helper only — it is not part of the box facade.
