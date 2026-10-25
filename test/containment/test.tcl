package require testme

set here [file dirname [info script]]
set root [file normalize $here/../..]
set helpers [file join [file dirname $here] selftest.tcl]
set sample [file join $root sample sample.tcl]

# A unit attempting to terminate the process is reported as a failure
unit -name unit-exit-contained [list apply {{helpers sample} {
  source $helpers
  lassign [capture tclsh $sample] code out
  expect attempt-failed [expr {[matching $out {^not ok \d+ - runaway$}] == 1}]
  expect attempt-reported [expr {[string match {*requested to terminate the process*} $out]}]
}} $helpers $sample]

# A suite script failing outright becomes a synthetic roster entry
unit -name failed-suite-synthetic [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name fine {return 1}
"]
  lappend pairs [list {broken test.tcl} "tcl::tm::add $root
package require testme
error {suite blew up}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect synthetic-entry [expr {[matching $out {^not ok \d+ - broken/test\.tcl$}] == 1}]
    expect roster [expr {[matching $out {^1\.\.2$}] == 1}]
    expect failed-exit [expr {$code == 1}]
    # The failed suite counts once: the synthetic unit carries the whole failure
    expect single-failure-tally [expr {[matching $out {^testme: 1 passed, 1 failed$}] == 1}]
  }
}} $helpers $root]

# A suite attempting to terminate the process is contained the same way
unit -name suite-exit-contained [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name survivor {return 1}
exit 0
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect attempt-reported [expr {[string match {*the suite code requested to terminate the process*} $out]}]
    expect unit-survived [expr {[matching $out {^ok \d+ - survivor$}] == 1}]
    expect failed-exit [expr {$code == 1}]
  }
}} $helpers $root]

# A unit attempting to change working directory is contained and reported as a failure
unit -name unit-cd-contained [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name try-cd {cd /tmp}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect attempt-reported [expr {[string match {*must not change working directory*} $out]}]
    expect attempt-failed [expr {[matching $out {^not ok \d+ - try-cd$}] == 1}]
    expect failed-exit [expr {$code == 1}]
  }
}} $helpers $root]
