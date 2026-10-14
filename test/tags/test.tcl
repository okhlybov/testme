package require testme

set here [file dirname [info script]]
set root [file normalize $here/../..]
set helpers [file join [file dirname $here] selftest.tcl]
set sample [file join $root sample sample.tcl]

# An include filter runs the tagged units and deselects the rest in place
unit -name include-filter [list apply {{helpers sample} {
  source $helpers
  lassign [capture tclsh $sample +smoke] code out
  expect tagged-ran [expr {[matching $out {^ok \d+ - alpha$}] == 1}]
  expect tagged-failed [expr {[matching $out {^not ok \d+ - runaway$}] == 1}]
  expect rest-deselected [expr {[matching $out {# SKIP deselected by tags$}] == 6}]
  expect plan-unchanged [expr {[matching $out {^1\.\.9$}] == 1}]
}} $helpers $sample]

# An exclude filter needs the option terminator; a bare word acts as an include
unit -name exclude-filter [list apply {{helpers sample} {
  source $helpers
  lassign [capture tclsh $sample -- -slow] code out
  expect slow-deselected [expr {[matching $out {# SKIP deselected by tags$}] == 3}]
  expect untagged-ran [expr {[matching $out {^ok \d+ - unit1$}] == 1}]
  lassign [capture tclsh $sample smoke] code out
  expect bare-word-includes [expr {[matching $out {# SKIP deselected by tags$}] == 6}]
}} $helpers $sample]
