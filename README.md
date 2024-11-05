# testme - a Tcl pico test suite

Testme is a test suite for the [Tcl langauge](https://www.tcl.tk/).

## Features

- Parallel unit execution
- Unit tagging & selective unit execution
- [TAP](https://testanything.org/)-compatible output

## Prerequisites

- Tcl 8.6+
- (optional) POSIX environment (UNIX, Linux, Cygwin, MSYS2 etc.) for supplied TAP consumer [`tapview`](https://gitlab.com/esr/tapview)

## Quickstart

Execute test suite

```shell
tclsh test/testme.tcl
```

Execute test suite & dump units output to the stdandrd error channel

```shell
tclsh test/testme.tcl -v
```

Filter test suite output with an external TAP consumer

```shell
tclsh test/testme.tcl | sh tapview
```

Review Testme command line options

```shell
tclsh test/testme.tcl -h
```

Each unit is equipped with a set of tags used to describe the test.
When a test suite containing the unit is run, this set is matched against tags specified in the command line to determine whether the particular unit is to be run or skipped.

### Test suite execution

A single test suite file is an ordinary Tcl source file which requires the `testme` package as its very first meaningful command.
The Testme package is looked up with the standard Tcl [module](https://wiki.tcl-lang.org/page/Tcl+Modules) loading mechanism.
If a specific Testme source is used to create independent relocatable test suite, the following preamble may be used:

```tcl
tcl::tm::add [file normalize [file join [file dirname [info script]] .. ..]]
package require testme
```

The above code instructs to search for Testme module in the directory `../..` relative to the directory containing the source file being executed.

The rest of the source is an ordinary Tcl script which can to anything including definitions for the test units to be processed.

#### Test suite lookup recursion

Prior executing custom code following the `testme` package loading command, the Testme searches for nested test suite sources to execute. The nested sources should have the same name as the current source file being executed and reside in its immediate subdirectories thus rigging for the recursive test suite processing. The recursion depth is unlimited by default and the user parts of the suites are processed in the depth first order. For example, for the toplevel source `test/testme.tcl` the Testme would also execute `test/nested/testme.tcl` if it exists.

For each test suite source the current directory is set to the directory containing this source. This way, the user part of the suite always has suite-specific files in `.` directory, regardless of recursion level. This also means that the suite can always determine the location of the Testme module and set the module location path accordingly as shown above.
