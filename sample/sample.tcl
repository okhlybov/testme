# Point to the local copy of testme in case it is not site-wide
tcl::tm::add [file normalize [file join [file dirname [info script]] ..]]

package require testme

namespace import testme::*

unit -name {successful set} {set x 1}

unit -name {failing set} {set y}

unit -name {list files} {puts [exec ls -l]}

set tags 1
with tags {2 3} {
  unit -name {parametrized} -tags $tags {puts [context -tags]}
}