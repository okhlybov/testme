# https://github.com/okhlybov/testme


package require Tcl 8.6
package require Thread


namespace eval ::testme {


  namespace export unit


  proc Import {source} {
    variable executor
    interp create box
    try {
      interp alias box ::testme::unit {} ::testme::unit
      box eval set ::nesting [incr $::nesting -1]
      box eval set argv0 [file normalize $source]
      box eval {
        cd [file dirname $argv0]
        if {[catch {source [file tail $argv0]} result]} {
          puts "error: $result"; # FIXME catch & report load errors
        }
      }
    } finally {
      interp delete box
    }
  }


  ### Toplevel code


  try {set ::nesting} on error {} {


    namespace eval ::tap {


        proc puts {args} {
          foreach x $args {::puts $x}
        }


    }


    set ::nesting -1


    variable executor [tpool::create -initcmd {
      set stdout [list]
      set stderr [list]
    }]


    variable pending [list]


    variable units [dict create]


    proc unit {args} {
      variable executor
      variable pending
      variable units
      set s [llength $args]
      if {$s < 1 || $s % 2 == 0} {error "usage: testme::unit ?-name ...? ?-tags ...? {...}"}
      set opts [lrange $args 0 end-1]
      set code [lindex [lrange $args end end] 0]
      set name unit[llength $pending]
      set tags [list]
      catch {set name [dict get $opts -name]}
      catch {set tags [dict get $opts -tags]}
      set n [dict size $units]; incr n
      dict set units $n [dict create -name $name -tags $tags -code $code]
      lappend pending [tpool::post $executor $code]
    }


    Import $argv0


    tap::puts "TAP version 14" "1..[dict size $units]"


    while {[llength $pending]} {
      set finished [tpool::wait $executor $pending pending]
      foreach f $finished {
        set pending [lsearch -inline -all -not -exact $pending $f]
        set name [dict get [dict get $units $f] -name]
        if {[catch {tpool::get $executor $f} result]} {
          tap::puts "not ok - $name" "  ---" "  message: $result" "  ..."
        } else {
          tap::puts "ok - $name"
        }
      }
    }


    exit 0


  }


  ### Nested code


  if {$::nesting != 0} {
    set wd [pwd]
    foreach source [glob -nocomplain [file join * [file tail $argv0]]] {
      try {Import $source} finally {cd $wd}
    }
  }


  ### Custom code which slurped the testme package's code


}