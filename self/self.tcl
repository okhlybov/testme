# The testme self-test: the framework proving itself by running generated
# suites through the real tclsh and asserting on their TAP output, exit
# codes and stderr. Run as `tclsh self/self.tcl` - all green, exit 0.


tcl::tm::add [file normalize [file join [file dirname [info script]] ..]]
package require testme


set root [file normalize [file join [file dirname [info script]] ..]]


# The unit-side helper library, prepended to every unit body: assertion
# helpers and the sub-suite runner. Executes in the unit interpreter, so it
# can use the `context` accessor and the `unit` record variable alike
set lib {
    proc expect {what cond} {
        if {!$cond} {error "expected: $what"}
        return
    }


    proc expect-match {what text pattern} {
        if {![regexp -- $pattern $text]} {
            error "expected $what matching /$pattern/\ngot: $text"
        }
        return
    }


    proc exitcode {opts} {
        if {[dict exists $opts -errorcode] && [lindex [dict get $opts -errorcode] 0] eq {CHILDSTATUS}} {
            return [lindex [dict get $opts -errorcode] 2]
        }
        return 0
    }


    # Generates a sub-suite (gen.tcl) in the unit staging directory, runs it
    # through the real tclsh and returns the outcome as a dict:
    #   code - tcl-level catch code, exit - the process exit status, out -
    #   the combined standard output & error channels
    proc run {body {args {}}} {
        package require buildme
        buildme::sandbox {
            set g [file join [dict get $unit -stage] gen.tcl]
            set f [open $g w]
            puts $f "cd {[dict get $unit -stage]}"
            puts $f "tcl::tm::add {[context -root]}"
            puts $f "tcl::tm::add {[dict get $unit -stage]}"
            puts $f {package require testme}
            puts $f $body
            close $f
            set caught [catch {exec [info nameofexecutable] $g {*}$args 2>@1} out opts]
            return [dict create code $caught exit [exitcode $opts] out $out]
        }
    }
}


# The suite-layer wrapper: composes the helper library into every unit body
proc unit-test {name body {opts {}}} {
    tailcall testme::unit -name $name -root $::root {*}$opts "$::lib\n$body"
}


### The context accessor


unit-test "context: flat and nested retrieval" {
    if {[context -fc] ne {flang}} {error "flat lookup mismatch"}
    if {[context -build cflags] ne {-O2}} {error "nested lookup mismatch"}
    if {[dict size [context -build]] != 2} {error "whole sub-dict mismatch"}
} {-fc flang -build {cflags {-O2} ldflags {-static}}}


unit-test "context: the whole record and dict get compatibility" {
    if {[dict get $unit -fc] ne {flang}} {error "dict get incompatibility"}
    if {[dict size [context]] < 5} {error "whole record too small"}
} {-fc flang}


unit-test "context: missing key fails the unit naming the key" {
    if {[catch {context -nope} e]} {
        if {![string match {*-nope*} $e]} {error "error does not name the key: $e"}
        return -code error $e
    }
    error "missing key did not fail"
}


### The unit facade


unit-test "facade: the testme package is requirable from unit code" {
    package require testme
    if {[info commands ::testme::with] eq {}} {error "with helper missing"}
    set acc {}
    set acc [testme::with acc {x} {lappend acc ok}]
    if {$acc ne {x ok}} {error "with mismatch"}
}


### The tapme consumer


unit-test "tapme: parser tallies, directives and outcome keywords" {
    package require tapme
    tapme::reset
    set marks {}
    lappend marks [tapme::line "1..3"]
    lappend marks [tapme::line "ok 1 - a"]
    lappend marks [tapme::line "not ok 2 - b"]
    lappend marks [tapme::line "ok 3 - c # SKIP later"]
    lappend marks [tapme::line "not ok 4 - d # TODO pending"]
    expect "outcome keywords" [join $marks ,] eq {,pass,fail,skip,todo}
    set s [join [tapme::summary] \n]
    expect-match "tally line" $s {4 of 3 tests: 1 passed, 1 failed, 1 skipped, 1 todo}
    expect-match "failed recap" $s {failed: 2 - b}
    expect "failed tally" [tapme::failed] == 1
}


unit-test "tapme: plan validation warnings" {
    package require tapme
    tapme::reset
    tapme::line "ok 1 - a"
    tapme::line "1..5"
    tapme::line "ok 2 - b"
    tapme::line "ok 9 - c"
    set s [join [tapme::summary] \n]
    expect-match "tests before plan warning" $s {tests before plan}
    expect-match "count mismatch warning" $s {expected 5 tests but 3 ran}
    expect-match "out of range warning" $s {out of range for the plan}
}


unit-test "tapme: the CLI consumes a stream" {
    package require buildme
    buildme::sandbox {
        set stage [dict get $unit -stage]
        set f [open [file join $stage stream.txt] w]
        puts $f "1..2"
        puts $f "ok 1 - a"
        puts $f "not ok 2 - b"
        close $f
        set tm [lindex [glob [file join [context -root] tapme-*.tm]] 0]
        set caught [catch {exec [info nameofexecutable] $tm < [file join $stage stream.txt]} out opts]
        expect "tapme exit 1 on failure" [exitcode $opts] == 1
        expect-match "progress marks" $out {.F}
        expect-match "summary" $out {2 of 2 tests: 1 passed, 1 failed}
        expect-match "failed recap" $out {failed: 2 - b}
    }
}


### Exit status


unit-test "exit status: all-pass with skip exits 0" {
    set r [run {
        testme::unit -name a {}
        testme::unit -name b {skip later}
        testme::unit -name c {}
    }]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "plan" [dict get $r out] {1\.\.3}
    expect-match "skip directive" [dict get $r out] {ok 2 - b # SKIP later}
}


unit-test "exit status: failure exits 1 with the reason in the YAML block" {
    set r [run {
        testme::unit -name good {}
        testme::unit -name bad {error boom}
    }]
    expect "exit 1" [dict get $r exit] == 1
    expect-match "not ok line" [dict get $r out] {not ok 2 - bad}
    expect-match "yaml reason" [dict get $r out] {return: boom}
}


unit-test "exit status: bail out stops at the first failure" {
    set r [run {
        testme::unit -name first {error stop-here}
        testme::unit -name second {}
    } -e]
    expect "exit 1" [dict get $r exit] == 1
    expect-match "bail out line" [dict get $r out] {Bail out!}
    expect "second unit never ran" [string match {*ok 2*} [dict get $r out]] == 0
}


unit-test "exit status: empty suite exits 0" {
    set r [run {testme::unit {}}]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "empty plan" [dict get $r out] {1\.\.1}
}


### Output suppression


unit-test "-q: stdout empty, tapme verdict on stderr" {
    package require buildme
    buildme::sandbox {
        set stage [dict get $unit -stage]
        set f [open [file join $stage q-sub.tcl] w]
        puts $f "tcl::tm::add {[context -root]}"
        puts $f {package require testme
            testme::unit -name good {}
            testme::unit -name bad {error x}
        }
        close $f
        set caught [catch {exec [info nameofexecutable] [file join $stage q-sub.tcl] -q > [file join $stage q-out.txt] 2> [file join $stage q-err.txt]} opts]
        expect "exit 1" [exitcode $opts] == 1
        set ch [open [file join $stage q-out.txt]]; set out [read $ch]; close $ch
        set ch [open [file join $stage q-err.txt]]; set err [read $ch]; close $ch
        expect "stdout empty" [string length [string trim $out]] == 0
        expect-match "tapme verdict" $err {2 of 2 tests: 1 passed, 1 failed}
        expect-match "failed recap" $err {failed: 2 - bad}
    }
}


### Containment


unit-test "containment: unit exit attempts are reported with arguments" {
    set r [run {
        testme::unit -name victim {exit 7}
        testme::unit -name bystander {}
    }]
    expect "exit 1" [dict get $r exit] == 1
    expect-match "victim fails" [dict get $r out] {not ok 1 - victim}
    expect-match "exit args reported" [dict get $r out] {terminate the process: exit 7}
    expect-match "bystander runs" [dict get $r out] {ok 2 - bystander}
}


unit-test "containment: broken nested suite becomes a synthetic failed unit" {
    set r [run {
        file mkdir b
        set f [open [file join b gen.tcl] w]
        puts $f {error broken-suite-code}
        close $f
        testme::unit -name a-ok {}
    }]
    expect "exit 1" [dict get $r exit] == 1
    expect-match "synthetic unit" [dict get $r out] {not ok \d+ - suite [^\n]*b[^\n]*gen\.tcl}
    expect-match "reason" [dict get $r out] {broken-suite-code}
    expect-match "parent runs" [dict get $r out] {ok \d+ - a-ok}
}


unit-test "containment: suite-level exit attempts are contained" {
    set r [run {
        file mkdir b
        set f [open [file join b gen.tcl] w]
        puts $f {exit 3}
        close $f
        testme::unit -name a-ok {}
    }]
    expect "exit 1" [dict get $r exit] == 1
    expect-match "synthetic unit" [dict get $r out] {not ok \d+ - suite}
}


unit-test "stale copies: vendored old generations are never sourced" {
    set r [run {
        file mkdir b
        set f [open [file join b testme-0.tm] w]
        puts $f {error STALE-SOURCED}
        close $f
        set f [open [file join b gen.tcl] w]
        puts $f {testme::unit -name b-ok {}}
        close $f
        testme::unit -name a-ok {}
    }]
    expect "exit 0" [dict get $r exit] == 0
    expect "stale copy untouched" [string match {*STALE-SOURCED*} [dict get $r out]] == 0
    expect-match "nested unit runs" [dict get $r out] {ok \d+ - b-ok}
}


### Nesting


unit-test "nesting: ancestry carries the true depth" {
    package require buildme
    buildme::sandbox {
        set stage [dict get $unit -stage]
        foreach d {a a/b a/b/c} {
            file mkdir [file join $stage $d]
            set f [open [file join $stage $d suite.tcl] w]
            puts $f "tcl::tm::add {[context -root]}"
            puts $f {package require testme
                puts stderr "depth [expr {[llength $::ancestors] - 1}]"
                testme::unit {}
            }
            close $f
        }
        set caught [catch {exec [info nameofexecutable] [file join $stage a suite.tcl] 2>@1} out opts]
        expect-match "depth 0" $out {depth 0}
        expect-match "depth 1" $out {depth 1}
        expect-match "depth 2" $out {depth 2}
    }
}


unit-test "nesting: symlink loops terminate" {
    package require buildme
    buildme::sandbox {
        set stage [dict get $unit -stage]
        file mkdir [file join $stage a] [file join $stage a b]
        foreach d {a a/b} {
            set f [open [file join $stage $d suite.tcl] w]
            puts $f "tcl::tm::add {[context -root]}"
            puts $f {package require testme
                testme::unit {}
            }
            close $f
        }
        if {[catch {file link -symbolic [file join $stage a b loop] [file join $stage a]} e]} {
            skip "symlink creation unavailable: $e"
        }
        set caught [catch {exec [info nameofexecutable] [file join $stage a suite.tcl] 2>@1} out opts]
        expect "terminates with exit 0" [exitcode $opts] == 0
        expect-match "both suites once" $out {1\.\.2}
    }
}


### The bare require guard


unit-test "guard: bare require in stdin mode is a catchable error" {
    package require buildme
    buildme::sandbox {
        set stage [dict get $unit -stage]
        set f [open [file join $stage driver.tcl] w]
        puts $f "tcl::tm::add {[context -root]}"
        puts $f {if {[catch {package require testme} e]} {puts "GUARDED: $e"} else {puts "MACHINERY-RAN"; exit 1}}
        close $f
        set out [exec [info nameofexecutable] < [file join $stage driver.tcl]]
        expect-match "guard message" $out {GUARDED:}
        expect "no machinery" [string match {*MACHINERY-RAN*} $out] == 0
    }
}


### The options


unit-test "options: --version prints the package version" {
    set out [exec [info nameofexecutable] --version 2>@1]
    expect-match "version format" $out {^[0-9]+(\.[0-9]+)*$}
}


unit-test "options: -h prints usage and exits 0" {
    set out [exec [info nameofexecutable] -h 2>@1]
    expect-match "usage line" $out {usage:}
}
