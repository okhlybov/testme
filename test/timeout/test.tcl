package require testme

set here [file dirname [info script]]
set root [file normalize $here/../..]
set helpers [file join [file dirname $here] selftest.tcl]

# A busy-looping unit is stopped by its -timeout and reported as failed
unit -name timeout-busy-loop [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name spin -timeout 1 {while {1} {}}
"]
  withfixture $pairs {
    set t0 [clock milliseconds]
    lassign [capture tclsh $dir/test.tcl] code out
    set dt [expr {[clock milliseconds] - $t0}]
    expect failed [expr {$code == 1}]
    expect reported [expr {[matching $out {^not ok 1 - spin$}] == 1}]
    expect message [expr {[matching $out {timed out after 1 s}] == 1}]
    expect prompt [expr {$dt < 8000}]
  }
}} $helpers $root]

# Fractional timeouts are honoured
unit -name timeout-fractional [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name quickspin -timeout 0.3 {while {1} {}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect failed [expr {$code == 1}]
    expect fractional-message [expr {[matching $out {timed out after 0\.3 s}] == 1}]
  }
}} $helpers $root]

# --timeout supplies the default for units without their own -timeout
unit -name timeout-default [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name spin {while {1} {}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl --timeout=1] code out
    expect failed [expr {$code == 1}]
    expect default-applied [expr {[matching $out {timed out after 1 s}] == 1}]
  }
}} $helpers $root]

# A unit -timeout overrides the --timeout default
unit -name timeout-override [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name spin -timeout 1 {while {1} {}}
unit -name quick {expr {1}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl --timeout=100] code out
    expect unit-timeout-wins [expr {[matching $out {timed out after 1 s}] == 1}]
    expect run-continues [expr {[matching $out {^ok \d+ - quick$}] == 1}]
  }
}} $helpers $root]

# An invalid -timeout fails the unit at once; the run continues
unit -name timeout-invalid [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name bad -timeout abc {expr {1}}
unit -name good {expr {1}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect invalid-failed [expr {[matching $out {^not ok 1 - bad$}] == 1}]
    expect invalid-message [expr {[matching $out {invalid -timeout: abc}] == 1}]
    expect run-continues [expr {[matching $out {^ok 2 - good$}] == 1}]
    expect failed-exit [expr {$code == 1}]
  }
}} $helpers $root]

# A timed out TODO unit stays an expected failure and passes the run
unit -name timeout-todo [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name expected -todo {known slow} -timeout 1 {while {1} {}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect todo-kept [expr {[matching $out {^not ok 1 - expected # TODO known slow$}] == 1}]
    expect timed-out [expr {[matching $out {timed out after 1 s}] == 1}]
  }
}} $helpers $root]

# The serial mode applies the time limits the same way
unit -name timeout-serial [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name spin -timeout 1 {while {1} {}}
unit -name quick {expr {1}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl -s] code out
    expect failed [expr {$code == 1}]
    expect reported [expr {[matching $out {^not ok 1 - spin$}] == 1}]
    expect message [expr {[matching $out {timed out after 1 s}] == 1}]
    expect run-continues [expr {[matching $out {^ok 2 - quick$}] == 1}]
  }
}} $helpers $root]
