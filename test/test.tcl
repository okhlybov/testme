# The testme self-test: the framework proving itself by running generated
# suites through the real tclsh and asserting on their TAP output, exit
# codes and stderr. Run as `tclsh self/self.tcl` - all green, exit 0.
#
# Top-level suite (Level 0): discovers nested suites recursively:
#   self/self.tcl -> self/nested/self.tcl -> self/nested/deep/self.tcl -> self/nested/deep/sub/self.tcl

set dir [file dirname [file normalize [info script]]]
while {![file isfile [file join $dir common.tcl]]} {
    set parent [file dirname $dir]
    if {$parent eq $dir} {error "cannot locate common.tcl"}
    set dir $parent
}
source [file join $dir common.tcl]


### The context accessor


unit-test "context: flat and nested retrieval" {
    if {[context -fc] ne {flang}} {error "flat lookup mismatch"}
    if {[context -build cflags] ne {-O2}} {error "nested lookup mismatch"}
    if {[dict size [context -build]] != 2} {error "whole sub-dict mismatch"}
} {-fc flang -build {cflags {-O2} ldflags {-static}}}


unit-test "context: the whole record and dict get compatibility" {
    if {[dict get [context] -fc] ne {flang}} {error "whole record lookup mismatch"}
    if {[dict get [context] -build cflags] ne {-O2}} {error "nested whole record lookup mismatch"}
} {-fc flang -build {cflags {-O2} ldflags {-static}}}


unit-test "context: missing key fails the unit naming the key" {
    set r [run {
        testme::unit -name accessor {
            context -missing
        }
    }]
    expect "exit 1" [dict get $r exit] == 1
    expect-match "accessor fails" [dict get $r out] {not ok 1 - accessor}
    expect-match "missing key in message" [dict get $r out] {key "-missing" not known}
}


### The unit facade


unit-test "facade: the testme package is requirable from unit code" {
    package require testme
    if {[info commands ::testme::with] eq {}} {error "with helper missing"}
    set acc {}
    set acc [testme::with acc {x} {lappend acc ok}]
    if {$acc ne {x ok}} {error "with mismatch"}
}


unit-test "facade: testme::with accumulates and processes values in unit code" {
    set r [run {
        testme::unit -name u_with_accum {
            package require testme
            set items {apple banana}
            set result [testme::with items {cherry date} {
                set joined [join $items ,]
                string toupper $joined
            }]
            if {$result ne "APPLE,BANANA,CHERRY,DATE"} {
                error "unexpected result: $result"
            }
        }
    }]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "unit succeeds" [dict get $r out] {ok 1 - u_with_accum}
}


unit-test "facade: testme::with handles uninitialized variable in unit code" {
    set r [run {
        testme::unit -name u_with_uninit {
            package require testme
            set total [testme::with numbers {10 20 30} {
                set sum 0
                foreach n $numbers {incr sum $n}
                set sum
            }]
            if {$total != 60} {
                error "unexpected sum: $total"
            }
        }
    }]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "unit succeeds" [dict get $r out] {ok 1 - u_with_uninit}
}


unit-test "facade: namespace import testme::* provides with helper in unit code" {
    set r [run {
        testme::unit -name u_with_import {
            package require testme
            namespace import testme::*
            set data {x}
            set out [with data {y z} {
                lindex $data 1
            }]
            if {$out ne "y"} {
                error "unexpected element: $out"
            }
        }
    }]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "unit succeeds" [dict get $r out] {ok 1 - u_with_import}
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
    set r [run {} --version]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "version format" [dict get $r out] {^[0-9]+(\.[0-9]+)*$}
}


unit-test "options: -h prints usage and exits 0" {
    set r [run {} -h]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "usage line" [dict get $r out] {usage:}
}


### Core / jobs detection


unit-test "jobs: DetectCores detects available cores and respects TESTME_JOBS" {
    set r [run {
        package require testme
        set detected [::testme::DetectCores]
        if {![string is integer -strict $detected] || $detected < 1} {
            error "invalid detected: $detected"
        }
        set ::env(TESTME_JOBS) 7
        if {[::testme::DetectCores] != 7} {
            error "TESTME_JOBS not honored: [::testme::DetectCores]"
        }
        testme::unit -name u_cores {}
    }]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "cores unit succeeds" [dict get $r out] {ok 1 - u_cores}
}
