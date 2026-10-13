# Level 2 nested self-test suite
# Tests: Exit status, Execution outcomes, Containment, Concurrency

set dir [file dirname [file normalize [info script]]]
while {![file isfile [file join $dir common.tcl]]} {
    set parent [file dirname $dir]
    if {$parent eq $dir} {error "cannot locate common.tcl"}
    set dir $parent
}
source [file join $dir common.tcl]


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


### Execution outcomes


unit-test "outcome: return -code ok is treated as success" {
    set r [run {
        testme::unit -name u_ok {
            return -code ok "value"
        }
    }]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "unit succeeds" [dict get $r out] {ok 1 - u_ok}
}


unit-test "outcome: return -code error reports custom failure" {
    set r [run {
        testme::unit -name u_custom {
            return -code error "explicit failure reason"
        }
    }]
    expect "exit 1" [dict get $r exit] == 1
    expect-match "unit fails" [dict get $r out] {not ok 1 - u_custom}
    expect-match "custom failure reason" [dict get $r out] {return: explicit failure reason}
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


### Concurrency


unit-test "jobs: -j limits worker concurrency and completes all units" {
    set r [run {
        testme::unit -name u1 {after 10}
        testme::unit -name u2 {after 10}
        testme::unit -name u3 {after 10}
    } -j 2]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "plan 1..3" [dict get $r out] {1\.\.3}
    expect-match "all units ran" [dict get $r out] {ok 3 - u3}
}


unit-test "jobs: --jobs= option is accepted" {
    set r [run {
        testme::unit -name u1 {}
    } --jobs=2]
    expect "exit 0" [dict get $r exit] == 0
    expect-match "unit ran" [dict get $r out] {ok 1 - u1}
}
