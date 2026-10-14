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
}} $helpers $sample]
