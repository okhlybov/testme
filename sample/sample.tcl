# Point to the local copy of testme in case it is not site-installed
tcl::tm::add [file normalize [file join [file dirname [info script]] ..]]

package require testme

unit {expr {6 * 7}}
unit -name failure {error {deliberate failure}}
unit -skip {not implemented yet} {error never-run}
unit -todo {known breakage} {error {expected failure}}