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

# A bare require from a clean interpreter finds no suite script to rerun
unit -name bare-require [list apply {{root helpers} {
  source $helpers
  tcl::tm::add $root
  set code [catch {package require testme} message]
  expect refused [expr {$code == 1 && [string match {*invalid ::argv0*} $message]}]
}} $root $helpers]

# The --version answer leaves before any machinery starts
unit -name version [list apply {{helpers sample} {
  source $helpers
  lassign [capture tclsh $sample --version] code out
  expect printed [expr {$code == 0 && [string trim $out] eq {0.1}}]
}} $helpers $sample]
