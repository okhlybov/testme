# testme - a Tcl testing pico framework
Testme is a testing framework for the [Tcl](https://www.tcl.tk/) language.

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

### Test suite invokation

The toplevel Testme suite is executed with any Tcl shell such as default `tclsh`. The Testme command line options are to be specified atfer the script file name as shown above.

#### Command line options

The full list of available options can be retrieved with the `-h` flag. The other important options are discussed below.

The `-j` option sets the maximum number of OS level threads to utilize during units execution. By default, Testme sets this to the number of detected processors/cores in the system.

The Testme rigs for separation of TAP and unit outputs in the way that all TAP output is dumped to the standard output channel which can be filtered with external tools like `tapview` while all logging and error processing output is dumped into the standard error channel making it possible for the shell pipeline below

```shell
tclsh test/testme.tcl -v 2> testme.log | sh tapview
```

where the unit execution progress and test suite summarizing report is done by the `tapview` while all error reports and log flood are accumulated in the `testme.log` file. The `-q` flag can be used to suppress the default TAP output completely effectively silencing the Testme. Conversely, the Testme is configured to suppress both standard and error outputs coming from Testme itself as well as from the units' code blocks (this also includes critical Tcl code errors). The `-v` flag enables all kinds of error and logging floods dumped to the standard error channel.

The default Testme behaviour is to execute all processed units that are not skipped in spite of encountered code errors or test failures. The `-e` flag can be used for bailing out on the first anomaly encountered. *Skipping a unit is not considered a failure.*

The `-T` flag enables the management of a temporary directory for Testme and processed units. This includes creating a temporary directory, setting up the `TMPDIR` environment variable and deleting this directory after unit execution phase (unless the `-K` flag is also specified, which is intended to retain the unit-generated garbage). *Refer to the Buildme module below.*

#### Command line arguments

The specified command line arguments which are not recongnized as options (or flags) are considered the tags for selective unit execution. The argument in form of `tag` or `+tag` represents a tag a unit must bear in order to be executed while the opposite `-tag` tag is used to prevent a unit from executing. In other words, for a unit to be executed is should bear at least one `+tag` and should not bear any of `-tag`s from the specified list of command line arguments. The order of tags does not matter. Empty `+` tag list means that all processed units are eligible for execution.

### Test suite processing

A single test suite is an ordinary Tcl source file which requires the `testme` package as its very first meaningful command.
The Testme package is looked up with the standard Tcl [module](https://wiki.tcl-lang.org/page/Tcl+Modules) loading mechanism.
If a specific Testme source is used to create independent relocatable test suite, the following preamble may be used:

```tcl
tcl::tm::add [file normalize [file join [file dirname [info script]] .. ..]]
package require testme
```

The above code instructs to search for Testme module in the directory `../..` relative to the directory containing the source file being executed.

The rest of the source is an ordinary Tcl script which can to anything including definitions for the test units to be processed.

#### Test suite lookup recursion

Prior executing custom code following the `testme` package loading command, the Testme searches for nested test suite sources to execute. The nested sources should have the same name as the current source file being executed and reside in its immediate subdirectories thus rigging for the recursive test suite processing. The recursion depth is unlimited by default and user parts of the test suites are processed in the depth first order. For example, prior the toplevel source `test/testme.tcl` the Testme would also execute `test/nested/testme.tcl` if it exists.

For each test suite source the current directory is set to the directory containing this source. This way, the user part of the suite always has suite-specific files in the `.` directory, regardless of recursion level. This also means that the suite can always determine the location of the Testme module and set the module location path accordingly in the way shown above.

#### Unit definition

A test unit is created with `testme::unit` command. Unit definition consists of a [dict](https://wiki.tcl-lang.org/page/dict)-like set of options and mandatory code block. A trivial no-op unit is defined as

```tcl
testme::unit {}
```

which denotes an auto-named unit bearing no tags attached and has  empty `{}` code block. This unit succeeds when executed.

An example of the full fledged unit follows

```tcl
testme::unit -name "unit name" -tags {tagA tagB} -input {OK} {
    puts [dict get $unit -input]
}
```

So far there are two special options, `-name` and `-tags` which are default-initialized to `unit#`  and `{}` if not specified, respectively. The rest of options is passed through of the unit code block.

The `-name` option represents the human-readable unit description. The `-tags` option represents a list of tags which are used to determine whether a particular unit is to be processed or skipped.

The mandatory code block specifies Tcl code executed with Tcl's [apply](https://wiki.tcl-lang.org/page/apply) command during unit execution phase. As the unit is executed in a pristine environment, its code block might contain proper Tcl script preamble, including loading required packages.

There are three outcomes of the unit's code block execution:

- success
  
  A successful outcome occurs when the execution passes the code block end without throwing an error or with `return` command without exit code or with exit code`0` (or `ok`).

- failure
  
  A failure occurs on any error or `return` with exit code other than `0` (or `ok`). Custom failure may be issued with Tcl's `error "reason"` command.

- skip
  
  A skip outcome is flagged with Testme's `skip "reason"` command. *Note that skipping is not considered a failure.*

#### Unit execution

Unit definitions follow the `package require testme` command and are processed sequentially in a separate per test suite source interpreter. Units are then executed in parallel in an unspecified order.

The units are independent from each other in the sense that there is no (predefined) way to pass or preserve information between them.

# Supplementaries

### Buildme

This package is intended to aid in the task of executing external commands from within the unit code blocks. The `buildme` module is to be loaded from the unit's code block as shown in the following example

```tcl
testme::unit {
    package require buildme
    buildme::sandbox {
        buildme::shell "touch .touchme"
    }
}
```

Here, the `buildme::sandbox` command creates a temporary directory inside the `$TMPDIR` directory, recursively copies the contents of a current directory (that is, the directory containing tes test suite source file being processed) to that newly created directory and executes the specified Tcl code block. Upon completion, is makes an attempt to delete the temporary directory (unless the Testme's `-K` flag is specified). The `TMPDIR` is either Testme-managed (refer to the Testme's `-T` command line flag) or is inherited from the execution environment.

In its turn, the `buildme::shell` command executes the specified shell comand using the `$SHELL` program (which is normally a command interpreter, such as Bash) from either unit suite's current directory or the temporary directory set up by the `buildme::sandbox`, if executed from within its code block.

The very purpose for this command pair is to aid in executing external commands which may produce (loads of) temporary file outputs along the way which should be retained for examination after unit execution and/or for the unit tests which have to be executed from write-protected locations yet needing to generate file outputs.



**Happy testing & have fun!**

Oleg A. Khlybov <fougas@mail.ru>
