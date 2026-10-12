# Level 3 nested self-test suite
# Tests: Tagging, Nesting, Symlinks, and Multilevel Nesting verification

set dir [file dirname [file normalize [info script]]]
while {![file isfile [file join $dir common.tcl]]} {
    set parent [file dirname $dir]
    if {$parent eq $dir} {error "cannot locate common.tcl"}
    set dir $parent
}
source [file join $dir common.tcl]


### Tagging & Selective Execution


unit-test "tags: positive tag runs matching units and skips others" {
    set r [run {
        testme::unit -name unit_a -tags {fast core} {}
        testme::unit -name unit_b -tags {slow} {}
        testme::unit -name unit_c -tags {fast} {}
    } +fast]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "matching unit_a runs" [dict get $r out] {ok 1 - unit_a}
    expect-match "non-matching unit_b skipped" [dict get $r out] {ok 2 - unit_b # SKIP}
    expect-match "matching unit_c runs" [dict get $r out] {ok 3 - unit_c}
}


unit-test "tags: negative tag skips matching units even if positive tag matches" {
    set r [run {
        testme::unit -name unit_a -tags {fast core} {}
        testme::unit -name unit_b -tags {fast slow} {}
        testme::unit -name unit_c -tags {core} {}
    } -- +fast -slow]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "unit_a runs" [dict get $r out] {ok 1 - unit_a}
    expect-match "unit_b skipped due to -slow" [dict get $r out] {ok 2 - unit_b # SKIP}
    expect-match "unit_c skipped due to lacking +fast" [dict get $r out] {ok 3 - unit_c # SKIP}
}


unit-test "tags: bare tag without plus behaves as positive tag" {
    set r [run {
        testme::unit -name unit_tagged -tags {smoke} {}
        testme::unit -name unit_untagged {}
    } smoke]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "tagged unit runs" [dict get $r out] {ok 1 - unit_tagged}
    expect-match "untagged unit skipped" [dict get $r out] {ok 2 - unit_untagged # SKIP}
}


### Nesting & Symlink loops


unit-test "exit status: -e bails out immediately on nested suite error" {
    set r [run {
        file mkdir bad_sub
        set f [open [file join bad_sub gen.tcl] w]
        puts $f {error fatal_suite_err}
        close $f
        testme::unit -name never_runs {}
    } -e]
    expect "exit 1" [dict get $r exit] == 1
    expect-match "bail out on error" [dict get $r out] {Bail out!}
    expect "unexecuted unit absent" [string match {*never_runs*} [dict get $r out]] == 0
}


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


### Multilevel Nesting Behaviors


unit-test "nesting: multi-tier suites execute all units in depth-first order across 4 levels" {
    package require buildme
    buildme::sandbox {
        set stage [dict get $unit -stage]
        foreach d {top top/l1 top/l1/l2 top/l1/l2/l3} {
            file mkdir [file join $stage $d]
            set f [open [file join $stage $d suite.tcl] w]
            puts $f "tcl::tm::add {[context -root]}"
            set tag [file tail $d]
            puts $f "package require testme
            testme::unit -name u_$tag {
                set x 1
            }"
            close $f
        }
        set caught [catch {exec [info nameofexecutable] [file join $stage top suite.tcl] 2>@1} out opts]
        expect "exit 0" [exitcode $opts] == 0
        expect-match "plan 1..4" $out {1\.\.4}
        expect-match "l3 runs" $out {ok \d+ - u_l3}
        expect-match "l2 runs" $out {ok \d+ - u_l2}
        expect-match "l1 runs" $out {ok \d+ - u_l1}
        expect-match "top runs" $out {ok \d+ - u_top}
    }
}


unit-test "nesting: tag filtering propagates across all nested hierarchy levels" {
    package require buildme
    buildme::sandbox {
        set stage [dict get $unit -stage]
        foreach d {top top/l1 top/l1/l2} {
            file mkdir [file join $stage $d]
            set f [open [file join $stage $d suite.tcl] w]
            puts $f "tcl::tm::add {[context -root]}"
            set tag [file tail $d]
            puts $f "package require testme
            testme::unit -name ${tag}_fast -tags fast {}
            testme::unit -name ${tag}_slow -tags slow {}"
            close $f
        }
        set caught [catch {exec [info nameofexecutable] [file join $stage top suite.tcl] +fast 2>@1} out opts]
        expect "exit 0" [exitcode $opts] == 0
        expect-match "plan 1..6" $out {1\.\.6}
        expect-match "top_fast runs" $out {ok \d+ - top_fast}
        expect-match "l1_fast runs" $out {ok \d+ - l1_fast}
        expect-match "l2_fast runs" $out {ok \d+ - l2_fast}
        expect-match "top_slow skipped" $out {ok \d+ - top_slow # SKIP}
        expect-match "l1_slow skipped" $out {ok \d+ - l1_slow # SKIP}
        expect-match "l2_slow skipped" $out {ok \d+ - l2_slow # SKIP}
    }
}


unit-test "nesting: deep failure at level 3 reports source and exits 1" {
    package require buildme
    buildme::sandbox {
        set stage [dict get $unit -stage]
        foreach d {top top/l1 top/l1/l2 top/l1/l2/l3} {
            file mkdir [file join $stage $d]
            set f [open [file join $stage $d suite.tcl] w]
            puts $f "tcl::tm::add {[context -root]}"
            if {$d eq "top/l1/l2/l3"} {
                puts $f {package require testme
                testme::unit -name deep_broken {error DEEP_FAIL}}
            } else {
                set tag [file tail $d]
                puts $f "package require testme
                testme::unit -name u_$tag {}"
            }
            close $f
        }
        set caught [catch {exec [info nameofexecutable] [file join $stage top suite.tcl] 2>@1} out opts]
        expect "exit 1" [exitcode $opts] == 1
        expect-match "deep unit fails" $out {not ok \d+ - deep_broken}
        expect-match "failure reason" $out {DEEP_FAIL}
        expect-match "source reported" $out {source: .*suite\.tcl}
    }
}


unit-test "nesting: -e bails out immediately on deep nested failure at level 3" {
    package require buildme
    buildme::sandbox {
        set stage [dict get $unit -stage]
        foreach d {top top/l1 top/l1/l2 top/l1/l2/l3} {
            file mkdir [file join $stage $d]
            set f [open [file join $stage $d suite.tcl] w]
            puts $f "tcl::tm::add {[context -root]}"
            if {$d eq "top/l1/l2/l3"} {
                puts $f {package require testme
                testme::unit -name deep_bailout {error STOP_DEEP}}
            } else {
                set tag [file tail $d]
                puts $f "package require testme
                testme::unit -name u_$tag {}"
            }
            close $f
        }
        set caught [catch {exec [info nameofexecutable] [file join $stage top suite.tcl] -e 2>@1} out opts]
        expect "exit 1" [exitcode $opts] == 1
        expect-match "bail out message" $out {Bail out!}
        expect-match "failing unit recorded" $out {not ok \d+ - deep_bailout}
        expect "later units never ran" [string match {*u_top*} $out] == 0
    }
}


unit-test "nesting: working directory is set to suite directory at every level" {
    package require buildme
    buildme::sandbox {
        set stage [dict get $unit -stage]
        foreach d {top top/l1 top/l1/l2} {
            file mkdir [file join $stage $d]
            set f [open [file join $stage $d suite.tcl] w]
            puts $f "tcl::tm::add {[context -root]}"
            set tag [file tail $d]
            puts $f "package require testme
            set here \[file normalize \[pwd\]\]
            set expected \[file normalize \[file dirname \[info script\]\]\]
            if {\$here ne \$expected} {
                puts stderr \"cwd mismatch at $tag: \$here vs \$expected\"
            } else {
                puts stderr \"cwd ok at $tag\"
            }
            testme::unit -name u_$tag {}"
            close $f
        }
        set caught [catch {exec [info nameofexecutable] [file join $stage top suite.tcl] 2>@1} out opts]
        expect "exit 0" [exitcode $opts] == 0
        expect-match "cwd top" $out {cwd ok at top}
        expect-match "cwd l1" $out {cwd ok at l1}
        expect-match "cwd l2" $out {cwd ok at l2}
    }
}
