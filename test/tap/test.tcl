package require testme

set here [file dirname [info script]]
set root [file normalize $here/../..]
set helpers [file join [file dirname $here] selftest.tcl]
set sample [file join $root sample sample.tcl]

# The leading plan and the strictly ascending roster of the 13 dialect
unit -name ordered-roster [list apply {{helpers sample} {
  source $helpers
  lassign [capture tclsh $sample --tap=13] code out
  set lines [split $out \n]
  expect nonzero-exit [expr {$code == 1}]
  expect header-first [expr {[lindex $lines 0] eq {TAP version 13}}]
  set plan [lsearch -exact $lines {1..9}]
  set first [lsearch -regexp $lines {^ok 1 }]
  expect plan-precedes-tests [expr {$plan >= 0 && $first > $plan}]
  expect roster-complete [expr {[matching $out {^(not )?ok \d+}] == 9}]
  set ids {}
  foreach line [lsearch -all -inline -regexp $lines {^(not )?ok \d+}] {
    regexp {^(?:not )?ok (\d+)} $line -> n
    lappend ids $n
  }
  expect ascending [expr {$ids eq {1 2 3 4 5 6 7 8 9}}]
}} $helpers $sample]

# The 14 dialect streams in completion order with the YAML diagnostics in place
unit -name streamed-roster [list apply {{helpers sample} {
  source $helpers
  lassign [capture tclsh $sample --tap=14] code out
  expect header-14 [expr {[lindex [split $out \n] 0] eq {TAP version 14}}]
  expect roster-complete [expr {[matching $out {^(not )?ok \d+}] == 9}]
  expect yaml-diagnostics [expr {[matching $out {^  message: \|}] >= 1}]
  expect nonzero-exit [expr {$code == 1}]
}} $helpers $sample]

# The empty roster takes the skip-all plan form
unit -name skip-all-plan [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list none.tcl "tcl::tm::add $root
package require testme
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/none.tcl] code out
    expect skip-all [expr {$code == 0 && [matching $out {^1\.\.0 # SKIP }] == 1}]
  }
}} $helpers $root]

# The driver command line validates its options
unit -name option-validation [list apply {{helpers sample} {
  source $helpers
  lassign [capture tclsh $sample --tap 12] code out
  expect bad-dialect [expr {$code == 1 && [string match {*unsupported TAP version*} $out]}]
  lassign [capture tclsh $sample --bogus] code out
  expect unknown-option [expr {$code == 1 && [string match {*unrecognized argument --bogus*} $out]}]
  lassign [capture tclsh $sample -j x] code out
  expect bad-jobs [expr {$code == 1 && [string match {*invalid job count*} $out]}]
  lassign [capture tclsh $sample -s -j 2] code out
  expect serial-jobs-conflict [expr {$code == 1 && [string match {*conflicts with -j/--jobs*} $out]}]
}} $helpers $sample]

# The -n option emits hierarchical TAP 14 indented subtests during descent
unit -name nested-subtests-descent [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name root-u1 { expr {1} }
"]
  lappend pairs [list sub/test.tcl "tcl::tm::add $root
package require testme
unit -name child-u1 { expr {1} }
unit -name child-u2 { expr {1} }
"]
  withfixture $pairs {
    # Default (flat mode)
    lassign [capture tclsh $dir/test.tcl] code out
    expect flat-exit [expr {$code == 0}]
    expect flat-plan [expr {[matching $out {^1\.\.3$}] == 1}]
    expect flat-no-subtest [expr {[matching $out {^# Subtest:}] == 0}]

    # Nested mode (-n)
    lassign [capture tclsh $dir/test.tcl -n] code out
    expect nested-exit [expr {$code == 0}]
    expect top-plan [expr {[matching $out {^1\.\.2$}] == 1}]
    expect subtest-header [expr {[matching $out {^# Subtest: sub$}] == 1}]
    expect subtest-plan [expr {[matching $out {^    1\.\.2$}] == 1}]
    expect subtest-tests [expr {[matching $out {^    ok [12] - child-u[12]$}] == 2}]
    expect subtest-close [expr {[matching $out {^ok 2 - sub$}] == 1}]
  }
}} $helpers $root]

# Programmatic in-suite subtest creates nested scopes and aggregates failures
unit -name nested-subtests-programmatic [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
subtest -name math {
  unit -name add { expr {1 + 1 == 2} }
  subtest -name deep {
    unit -name fail { error \"deep failure\" }
  }
}
unit -name standalone { expr {1} }
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl -n] code out
    expect failure-exit [expr {$code == 1}]
    expect top-plan [expr {[matching $out {^1\.\.2$}] == 1}]
    expect subtest-math [expr {[matching $out {^# Subtest: math$}] == 1}]
    expect subtest-deep [expr {[matching $out {^    # Subtest: deep$}] == 1}]
    expect deep-plan [expr {[matching $out {^        1\.\.1$}] == 1}]
    expect deep-fail [expr {[matching $out {^        not ok 1 - fail$}] == 1}]
    expect deep-parent-fail [expr {[matching $out {^    not ok 2 - deep$}] == 1}]
    expect math-parent-fail [expr {[matching $out {^not ok 1 - math$}] == 1}]
    expect standalone-ok [expr {[matching $out {^ok 2 - standalone$}] == 1}]
  }
}} $helpers $root]

# The -n option is disabled in TAP 13 mode
unit -name nested-disabled-tap13 [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name root-u1 { expr {1} }
"]
  lappend pairs [list sub/test.tcl "tcl::tm::add $root
package require testme
unit -name child-u1 { expr {1} }
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl --tap=13 -n] code out
    expect tap13-exit [expr {$code == 0}]
    expect tap13-header [expr {[matching $out {^TAP version 13$}] == 1}]
    expect tap13-plan [expr {[matching $out {^1\.\.2$}] == 1}]
    expect tap13-no-subtest [expr {[matching $out {Subtest}] == 0}]
    expect tap13-flat [expr {[matching $out {^ok [12] - }] == 2}]
  }
}} $helpers $root]

# The -s option executes units sequentially without a thread pool
unit -name serial-execution-mode [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name u1 { expr {1 + 1 == 2} }
unit -name u2 { expr {2 * 3 == 6} }
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl -s] code out
    expect clean-exit [expr {$code == 0}]
    expect plan-line [expr {[matching $out {^1\.\.2$}] == 1}]
    expect u1-ok [expr {[matching $out {^ok 1 - u1$}] == 1}]
    expect u2-ok [expr {[matching $out {^ok 2 - u2$}] == 1}]
    expect summary [expr {[matching $out {^testme: 2 passed, 0 failed$}] == 1}]
  }
}} $helpers $root]

# Missing Thread package silently falls back to serial mode, but errors if -j is specified
unit -name serial-fallback-no-thread [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package forget Thread
rename package ::_orig_package
proc package {args} {
  if {\[lindex \$args 0\] eq {require} && \[lindex \$args 1\] eq {Thread}} {
    error \"can't find package Thread\"
  }
  tailcall ::_orig_package {*}\$args
}
package require testme
unit -name u1 { expr {10} }
"]
  withfixture $pairs {
    # Without -j: degrades to serial mode
    lassign [capture tclsh $dir/test.tcl] code out
    expect silent-fallback [expr {$code == 0 && [matching $out {^ok 1 - u1$}] == 1}]

    # With -j: explicit error
    lassign [capture tclsh $dir/test.tcl -j 2] code out
    expect jobs-error [expr {$code == 1 && [string match {*-j/--jobs requires the Thread package*} $out]}]
  }
}} $helpers $root]

# The TESTME_OPTS environment variable supplies default options and filters
unit -name testme-opts [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list tap13.tcl "set ::env(TESTME_OPTS) {--tap=13}
tcl::tm::add $root
package require testme
unit -name u1 { expr {1} }
"]
  lappend pairs [list serial.tcl "set ::env(TESTME_OPTS) {-s}
tcl::tm::add $root
package require testme
unit -name u1 { expr {1} }
unit -name u2 { expr {2} }
"]
  lappend pairs [list jobs.tcl "set ::env(TESTME_OPTS) {-j 2}
tcl::tm::add $root
package require testme
unit -name u1 { expr {1} }
unit -name u2 { expr {2} }
"]
  lappend pairs [list filter.tcl "set ::env(TESTME_OPTS) {+fast}
tcl::tm::add $root
package require testme
unit -name u1 -tags {fast} { expr {1} }
unit -name u2 -tags {slow} { expr {2} }
"]
  lappend pairs [list badopt.tcl "set ::env(TESTME_OPTS) {--bogus-opt}
tcl::tm::add $root
package require testme
unit -name u1 { expr {1} }
"]
  lappend pairs [list badquote.tcl "set ::env(TESTME_OPTS) \"\\\"-unclosed\"
tcl::tm::add $root
package require testme
unit -name u1 { expr {1} }
"]
  lappend pairs [list conflict.tcl "set ::env(TESTME_OPTS) {-s -j 2}
tcl::tm::add $root
package require testme
unit -name u1 { expr {1} }
"]
  withfixture $pairs {
    # 1. TESTME_OPTS setting dialect to TAP 13
    lassign [capture tclsh $dir/tap13.tcl] code out
    expect tap13-env [expr {$code == 0 && [matching $out {^TAP version 13$}] == 1}]

    # 2. Command line overrides TESTME_OPTS
    lassign [capture tclsh $dir/tap13.tcl --tap=14] code out
    expect tap14-cli-override [expr {$code == 0 && [matching $out {^TAP version 14$}] == 1}]

    # 3. TESTME_OPTS setting serial mode (-s)
    lassign [capture tclsh $dir/serial.tcl] code out
    expect serial-env [expr {$code == 0 && [matching $out {^ok 1 - u1$}] == 1 && [matching $out {^ok 2 - u2$}] == 1}]

    # 4. CLI -j overrides TESTME_OPTS -s
    lassign [capture tclsh $dir/serial.tcl -j 1] code out
    expect cli-jobs-overrides-serial [expr {$code == 0}]

    # 5. CLI -s overrides TESTME_OPTS -j
    lassign [capture tclsh $dir/jobs.tcl -s] code out
    expect cli-serial-overrides-jobs [expr {$code == 0 && [matching $out {^ok 1 - u1$}] == 1}]

    # 6. Tag filtering via TESTME_OPTS
    lassign [capture tclsh $dir/filter.tcl] code out
    expect filter-env [expr {$code == 0 && [matching $out {^ok \d+ - u1$}] == 1 && [matching $out {^ok \d+ - u2 # SKIP}] == 1}]

    # 7. Invalid option in TESTME_OPTS
    lassign [capture tclsh $dir/badopt.tcl] code out
    expect bad-opt-env [expr {$code == 1 && [string match {*invalid TESTME_OPTS: unrecognized argument --bogus-opt*} $out]}]

    # 8. Malformed list / unclosed quote in TESTME_OPTS
    lassign [capture tclsh $dir/badquote.tcl] code out
    expect bad-quote-env [expr {$code == 1 && [string match {*invalid TESTME_OPTS: unmatched open quote*} $out]}]

    # 9. Incompatible options inside TESTME_OPTS itself
    lassign [capture tclsh $dir/conflict.tcl] code out
    expect conflict-env [expr {$code == 1 && [string match {*invalid TESTME_OPTS: -s/--serial conflicts with -j/--jobs*} $out]}]
  }
}} $helpers $root]



