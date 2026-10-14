# The testme self test suite: the framework exercising itself over the sample
# and over the scratch fixtures built on the fly.
# The feature areas live in the subdirectories and join in as sub-suites

# Point to the local copy of testme in case it is not site-installed
tcl::tm::add [file normalize [file join [file dirname [info script]] ..]]

package require testme

set here [file dirname [info script]]
set root [file normalize $here/..]
set helpers [file join $here selftest.tcl]
set sample [file join $root sample sample.tcl]

# A bare require from a stub-less interpreter finds no suite script to rerun
unit -name bare-require [list apply {{root helpers} {
  source $helpers
  set script "tcl::tm::add $root\nif {\[catch {package require testme} err\]} {puts stderr \$err; exit 1}"
  lassign [capture [info nameofexecutable] << $script] code out
  expect refused [expr {$code == 1 && [string match {*invalid ::argv0*} $out]}]
}} $root $helpers]

# The unit layer face: the require inside the unit code is answered
# by the provide-only stub, the helpers are already planted
unit -name unit-layer-face [list apply {{root helpers} {
  source $helpers
  tcl::tm::add $root
  expect provided [expr {[package require testme] eq {0.1}}]
  expect helpers [expr {[llength [info commands ::testme::with]] == 1}]
}} $root $helpers]

# The unit layer with accumulator: validates lexical nesting and list accumulation
unit -name unit-with-accumulation [list apply {{root helpers} {
  source $helpers
  set res [::testme::with tags {smoke} {
    set inner [::testme::with tags {fast critical} {
      set tags
    }]
    list $tags $inner
  }]
  expect outer-tags [expr {[lindex $res 0] eq {smoke}}]
  expect inner-tags [expr {[lindex $res 1] eq {smoke fast critical}}]
}} $root $helpers]

# The suite-level with accumulator: scopes tags across child units and sub-withs
unit -name suite-with-scoping [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
testme::with tags {suite-tag} {
  unit -name u1 -tags \$tags { expr {1} }
  testme::with tags {nested-tag} {
    unit -name u2 -tags \$tags { expr {2} }
  }
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl +suite-tag] code out
    expect both-run [expr {[matching $out {^ok \d+ - u[12]$}] == 2}]
    lassign [capture tclsh $dir/test.tcl +nested-tag] code out
    expect nested-only-ran [expr {[matching $out {^ok \d+ - u2$}] == 1}]
    expect u1-deselected [expr {[matching $out {^ok \d+ - u1 # SKIP deselected by tags$}] == 1}]
  }
}} $helpers $root]

# The --version answer leaves before any machinery starts
unit -name version [list apply {{helpers sample} {
  source $helpers
  lassign [capture tclsh $sample --version] code out
  expect printed [expr {$code == 0 && [string trim $out] eq {0.1}}]
}} $helpers $sample]
