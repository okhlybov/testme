::tcl::tm::add [file join [file dirname [info script]] .. ..]

package require testme

namespace import testme::*

# Blank unit
unit {}

# Skipped unit
unit {skip N/A}