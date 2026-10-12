# Level 1 nested self-test suite
# Tests: Tapme consumer, Output suppression, Dumps, Log persistence, Environment hints

set dir [file dirname [file normalize [info script]]]
while {![file isfile [file join $dir common.tcl]]} {
    set parent [file dirname $dir]
    if {$parent eq $dir} {error "cannot locate common.tcl"}
    set dir $parent
}
source [file join $dir common.tcl]


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
    expect-match "tests before plan warning" $s {plan line may only be placed before or after}
    expect-match "count mismatch warning" $s {expected 5 tests but only 3 ran}
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


### Output suppression & dumps


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
        set caught [catch {exec [info nameofexecutable] [file join $stage q-sub.tcl] -q > [file join $stage q-out.txt] 2> [file join $stage q-err.txt]} out opts]
        expect "exit 1" [exitcode $opts] == 1
        set ch [open [file join $stage q-out.txt]]; set out [read $ch]; close $ch
        set ch [open [file join $stage q-err.txt]]; set err [read $ch]; close $ch
        expect "stdout empty" [string length [string trim $out]] == 0
        expect-match "tapme verdict" $err {2 of 2 tests: 1 passed, 1 failed}
        expect-match "failed recap" $err {failed: 2 - bad}
    }
}


unit-test "output: -v and -F dump succeeded unit output to stderr" {
    set r [run {
        testme::unit -name quiet_ok {
            puts "OUTPUT_FROM_SUCCEEDED_UNIT"
        }
    } -v -F]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "-F dumped stdout" [dict get $r out] {OUTPUT_FROM_SUCCEEDED_UNIT}
}


unit-test "output: -v dumps failed unit output to stderr" {
    set r [run {
        testme::unit -name failing_loud {
            puts "FAILURE_STDOUT_PAYLOAD"
            error "FAIL_ERR"
        }
    } -v]
    expect "exit 1" [dict get $r exit] == 1
    expect-match "-v dumped stdout" [dict get $r out] {FAILURE_STDOUT_PAYLOAD}
}


### Log persistence


unit-test "keep: -K preserves per-unit log files" {
    package require buildme
    buildme::sandbox {
        set stage [dict get $unit -stage]
        set f [open [file join $stage k-sub.tcl] w]
        puts $f "tcl::tm::add {[context -root]}"
        puts $f "cd {[file normalize $stage]}"
        puts $f {package require testme
            testme::unit -name logged {
                puts stdout "PERSISTED_OUTPUT"
            }
        }
        close $f
        set caught [catch {exec [info nameofexecutable] [file join $stage k-sub.tcl] -K 2>@1} out opts]
        expect "exit 0" [exitcode $opts] == 0
        set logfiles [glob -nocomplain [file join $stage "*logged*stdout.out"]]
        expect "log file created" [llength $logfiles] == 1
        set ch [open [lindex $logfiles 0]]
        set content [read $ch]
        close $ch
        expect-match "log content preserved" $content {PERSISTED_OUTPUT}
    }
}


### Environment hints


unit-test "hints: TESTME_THREAD_DIR is propagated and populated in env" {
    expect "env hint populated" [info exists ::env(TESTME_THREAD_DIR)] == 1
    expect "hint points to valid pkgIndex.tcl" [file isfile [file join $::env(TESTME_THREAD_DIR) pkgIndex.tcl]] == 1
    set r [run {
        testme::unit -name child_hint {
            if {![info exists ::env(TESTME_THREAD_DIR)]} {error "TESTME_THREAD_DIR not inherited"}
            if {![file isfile [file join $::env(TESTME_THREAD_DIR) pkgIndex.tcl]]} {error "invalid pkgIndex in child"}
        }
    }]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "child unit runs" [dict get $r out] {ok 1 - child_hint}
}
