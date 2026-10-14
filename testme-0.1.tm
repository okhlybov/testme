package require Tcl 8.6-


namespace eval ::testme {


if {[info exists Context]} { set context {nested} } else { set context {toplevel} }


# Define the unit to be run
proc unit {args} {
  set nargs [llength $args]
  if {$nargs < 1 || $nargs % 2 == 0} {error "usage: testme::unit ?-name ...? ?-tags ...? {code...}"}
}


# Perform recursive descent into immediate subdirectories of the root in search of the sources with the memorized name
# Each descention level is run in the isolated subinterpreter
proc Descend {root} {
  variable Context
  interp create descended
  try {
    # Set up the augmented context in the descended child interpreter
    descended eval { namespace eval testme {} }
    descended eval [list set testme::Context [dict merge $Context [dict create -root $root]]]
    descended eval {
      # Add up new paths to the module lookup list
      set current [tcl::tm::path list]
      foreach x [lreverse [dict get $testme::Context tcl::tm::path]] {
        # Squash duplicates in the module lookup path
        if {[lsearch $current $x] < 0} {
          tcl::tm::path add $x
        }
      }
      # Memorize new module lookup list for propagation
      dict set testme::Context tcl::tm::path [tcl::tm::path list]
    }
    # Source the file sharing the name yet from the nested directory
    descended eval {source [file join [dict get $testme::Context -root] [dict get $testme::Context -script]]}
  } finally {
    interp delete descended
  }
}


### Toplevel context setup
if {$context eq {toplevel}} {

  package require Thread

  set pool [tpool::create -maxworkers 4]
  tpool::preserve $pool

  set Context [dict create \
    -root [file dirname [file normalize $argv0]] \
    -script [file tail $::argv0] \
      tcl::tm::path [tcl::tm::path list] \
  ]

}


# Look for the scripts sharing name with the current one in the immediate subdirectories of $root
foreach source [glob -nocomplain -directory [dict get $Context -root] [file join * [dict get $Context -script]]] {
  # Normalized root path to the script to be evaluated in the subinterpreter
  Descend [file dirname [file normalize $source]]
}


### Toplevel context cleanup
if {$context eq {toplevel}} {

  tpool::release $pool

}


}