package require testme

set here [file dirname [info script]]
set root [file normalize $here/../..]
set helpers [file join [file dirname $here] selftest.tcl]

# A script composed by an umbrella is never rerun by the descent discovery
unit -name umbrella-single-run [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list all.tcl "tcl::tm::add $root
source \[file dirname \[info script\]\]/comp.tcl
source \[file dirname \[info script\]\]/sub/all.tcl
"]
  lappend pairs [list comp.tcl "tcl::tm::add $root
package require testme
unit -name comp {return one}
"]
  lappend pairs [list {sub all.tcl} "tcl::tm::add $root
package require testme
unit -name nested {return deep}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/all.tcl] code out
    expect composed-runs [expr {[matching $out {^ok \d+ - comp$}] == 1}]
    expect nested-once [expr {[matching $out {^ok \d+ - nested$}] == 1}]
    expect roster [expr {[matching $out {^1\.\.2$}] == 1}]
    expect clean-exit [expr {$code == 0}]
  }
}} $helpers $root]

# A symlinked twin of a suite collapses into the same file identity
unit -name symlink-single-run [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list all.tcl "tcl::tm::add $root
package require testme
unit -name root {return top}
"]
  lappend pairs [list {sub all.tcl} "tcl::tm::add $root
package require testme
unit -name nested {return deep}
"]
  withfixture $pairs {
    file link -symbolic [file join $dir twin] [file join $dir sub]
    lassign [capture tclsh $dir/all.tcl] code out
    expect twin-skipped [expr {[matching $out {^ok \d+ - nested$}] == 1}]
    expect roster [expr {[matching $out {^1\.\.2$}] == 1}]
    expect clean-exit [expr {$code == 0}]
  }
}} $helpers $root]
