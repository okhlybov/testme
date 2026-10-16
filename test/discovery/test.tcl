package require testme

set here [file dirname [info script]]
set root [file normalize $here/../..]
set helpers [file join [file dirname $here] selftest.tcl]

# Suite stdout during collection is refused: stdout is the TAP channel of
# the run itself, and stray lines (or forgeries) have no business there
unit -name discovery-stdout-denied [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
puts {ok 99 - forged}
unit -name u {expr {1}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect failed-exit [expr {$code == 1}]
    expect no-forgery [expr {[matching $out {^ok 99}] == 0}]
    expect denied [expr {[matching $out {must not write to stdout during collection; use stderr}] >= 1}]
    expect unit-planned [expr {[matching $out {^1\.\.1$}] == 1}]
  }
}} $helpers $root]

# Suite stderr stays free for the suite's own diagnostics
unit -name discovery-stderr-free [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
puts stderr diag-plain
chan puts stderr chan-diag
unit -name u {expr {1}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect diag-raw [expr {[matching $out {^diag-plain$}] == 1}]
    expect chan-diag-raw [expr {[matching $out {^chan-diag$}] == 1}]
    expect unit-ran [expr {[matching $out {^ok \d+ - u$}] == 1}]
  }
}} $helpers $root]

# A sub-suite writing to stdout during descent is refused the same way
unit -name discovery-subsuite-denied [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
"]
  lappend pairs [list {sub test.tcl} "tcl::tm::add $root
package require testme
puts {not ok 5 - deeper forgery}
unit -name deep {expr {1}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect failed-exit [expr {$code == 1}]
    expect no-forgery [expr {[matching $out {^not ok 5}] == 0}]
    expect denied [expr {[matching $out {must not write to stdout during collection}] >= 1}]
  }
}} $helpers $root]

# A program a suite launches cannot write onto the process streams either
unit -name discovery-exec-redirect-denied [list apply {{helpers root} {
  source $helpers
  if {$::tcl_platform(platform) eq "windows"} {
    skip {POSIX shell assumed}
  }
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
exec echo FORGED-DURING-DISCOVERY >@ stdout
unit -name u {expr {1}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect failed-exit [expr {$code == 1}]
    expect stream-clean [expr {[matching $out {^FORGED-DURING-DISCOVERY$}] == 0}]
    expect denied [expr {[matching $out {must not write to the process streams.*redirection to stdout}] >= 1}]
  }
}} $helpers $root]
