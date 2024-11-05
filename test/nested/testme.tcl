tcl::tm::add [file normalize [file join [file dirname [info script]] .. ..]]

package require testme

# Blank unit
testme::unit {}

# Skipped unit
testme::unit {skip N/A}