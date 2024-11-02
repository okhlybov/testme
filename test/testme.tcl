::tcl::tm::add [file join [file dirname [info script]] ..]

package require testme

namespace import testme::*

unit -name {successful set} {set x 1}

unit -name {failing set} {set y}

unit -name {list files} {puts [exec ls -l]}