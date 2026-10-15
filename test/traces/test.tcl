package require testme

set here [file dirname [info script]]
set root [file normalize $here/../..]
set helpers [file join [file dirname $here] selftest.tcl]

# The failure trace ends at the unit body boundary: no runner frames leak
unit -name trace-trimmed [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name boom {
  set a 1
  set b 2
  error {kaboom}
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect failed [expr {$code == 1}]
    expect boundary-frame [expr {[matching $out {\(unit "boom" line 4\)}] == 1}]
    expect no-runner-frames [expr {[matching $out {interp eval}] == 0}]
    expect no-lambda-frames [expr {[matching $out {lambda term}] == 0}]
    expect kaboom-first [expr {[matching $out {^    kaboom$}] == 1}]
  }
}} $helpers $root]

# -F keeps the full trace for debugging the framework itself
unit -name trace-full-dump [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name boom {error {kaboom}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl -F] code out
    expect full-trace-kept [expr {[matching $out {invoked from within}] >= 2}]
  }
}} $helpers $root]

# The skip return code still crosses the named body procedure untouched
unit -name trace-skip-still-works [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name self-skip {
  set pre 1
  skip {not today}
}
unit -name survivor {expr {1}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect skipped [expr {[matching $out {^ok \d+ - self-skip # SKIP not today$}] == 1}]
    expect pre-ran-no-error [expr {[matching $out {^    pre}] == 0}]
    expect survivor [expr {[matching $out {^ok \d+ - survivor$}] == 1}]
  }
}} $helpers $root]
