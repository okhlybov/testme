package require testme

set here [file dirname [info script]]
set root [file normalize $here/../..]
set helpers [file join [file dirname $here] selftest.tcl]

# Text printed by a suite script while it is being collected becomes a comment
unit -name discovery-puts-commented [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
puts hello-discovery
unit -name u {expr {1}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect commented [expr {[matching $out {^# hello-discovery$}] == 1}]
    expect unit-ran [expr {[matching $out {^ok \d+ - u$}] == 1}]
  }
}} $helpers $root]

# TAP lookalikes printed during discovery cannot forge results of this run
unit -name discovery-forgery-neutralized [list apply {{helpers root tapme} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
puts {ok 99 - forged}
puts {Bail out! fake}
unit -name real {expr {1}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect forged-commented [expr {[matching $out {^# ok 99 - forged$}] == 1}]
    expect bail-commented [expr {[matching $out {^# Bail out! fake$}] == 1}]
    expect unit-ran [expr {[matching $out {^ok 1 - real$}] == 1}]
    # an independent consumer must not be fooled either
    lassign [capture tclsh $dir/test.tcl | tclsh $tapme] c2 out2
    expect consumer-clean [expr {$c2 == 0}]
    expect consumer-count [expr {[matching $out2 {^# 1 of 1 tests: 1 passed, 0 failed}] == 1}]
  }
}} $helpers $root [file join $root extra tapme-0.tm]]

# A trailing partial line still receives its comment marker
unit -name discovery-partial-line [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
puts -nonewline partial-tail
unit -name u {expr {1}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect partial-commented [expr {[matching $out {^# partial-tail$}] == 1}]
    expect clean-exit [expr {$code == 0}]
  }
}} $helpers $root]

# Suite stderr stays untouched: only the TAP-bearing stdout channel is guarded
unit -name discovery-stderr-untouched [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
puts stderr diag-plain
unit -name u {expr {1}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect diag-raw [expr {[matching $out {^diag-plain$}] == 1}]
    expect diag-not-commented [expr {[matching $out {^# diag-plain$}] == 0}]
  }
}} $helpers $root]

# A sub-suite printing during descent is contained the same way
unit -name discovery-subsuite-contained [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
puts {top-level line}
"]
  lappend pairs [list {sub test.tcl} "tcl::tm::add $root
package require testme
puts {not ok 5 - deeper forgery}
unit -name deep {expr {1}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect top-commented [expr {[matching $out {^# top-level line$}] == 1}]
    expect deep-commented [expr {[matching $out {^# not ok 5 - deeper forgery$}] == 1}]
    expect deep-unit-ran [expr {[matching $out {^ok \d+ - deep$}] == 1}]
  }
}} $helpers $root]
