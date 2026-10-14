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

# Module lookup paths added by an enclosing suite propagate down to child suites and unit workers
unit -name nested-module-path-propagation [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list {modules mymod-1.0.tm} {
    package provide mymod 1.0
    proc ::mymod_greeting {} { return "hello from mymod" }
  }]
  lappend pairs [list all.tcl "tcl::tm::add $root
tcl::tm::path add \[file normalize \[file dirname \[info script\]\]/modules\]
package require testme
"]
  lappend pairs [list {sub all.tcl} "package require testme
package require mymod
unit -name check-inherited-module {
  package require mymod
  return \[::mymod_greeting\]
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/all.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect unit-ok [expr {[matching $out {^ok \d+ - check-inherited-module$}] == 1}]
  }
}} $helpers $root]

# The -S/--source option overrides the descent script name so orthogonal suites coexist
unit -name descent-source-selection [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list all.tcl "tcl::tm::add $root
package require testme
unit -name top-unit {return top}
"]
  lappend pairs [list {sub component.tcl} "package require testme
unit -name sub-component {return comp}
"]
  lappend pairs [list {sub other.tcl} "package require testme
unit -name sub-other {return other}
"]
  withfixture $pairs {
    # Default descent (looks for all.tcl) finds no children in sub/
    lassign [capture tclsh $dir/all.tcl] code1 out1
    expect default-clean [expr {$code1 == 0}]
    expect default-roster [expr {[matching $out1 {^1\.\.1$}] == 1}]
    expect default-top [expr {[matching $out1 {^ok \d+ - top-unit$}] == 1}]

    # -S component.tcl discovers sub/component.tcl
    lassign [capture tclsh $dir/all.tcl -S component.tcl] code2 out2
    expect short-s-clean [expr {$code2 == 0}]
    expect short-s-roster [expr {[matching $out2 {^1\.\.2$}] == 1}]
    expect short-s-top [expr {[matching $out2 {^ok \d+ - top-unit$}] == 1}]
    expect short-s-comp [expr {[matching $out2 {^ok \d+ - sub-component$}] == 1}]
    expect short-s-no-other [expr {[matching $out2 {sub-other}] == 0}]

    # --source=other.tcl discovers sub/other.tcl
    lassign [capture tclsh $dir/all.tcl --source=other.tcl] code3 out3
    expect long-source-clean [expr {$code3 == 0}]
    expect long-source-roster [expr {[matching $out3 {^1\.\.2$}] == 1}]
    expect long-source-top [expr {[matching $out3 {^ok \d+ - top-unit$}] == 1}]
    expect long-source-other [expr {[matching $out3 {^ok \d+ - sub-other$}] == 1}]
    expect long-source-no-comp [expr {[matching $out3 {sub-component}] == 0}]
  }
}} $helpers $root]
