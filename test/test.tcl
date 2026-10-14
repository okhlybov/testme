# Point to the local copy of testme in case it is not site-installed
tcl::tm::add [file normalize [file join [file dirname [info script]] ..]]

package require testme

puts .