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
        source [file tail $argv0]
      }
    } finally {
      interp delete box
    }
  }


  ### Toplevel code


  try {set ::nesting} on error {} {


    try {


      set ::nesting -1


      ### Executing thread code


      variable executor [tpool::create -initcmd {


        proc lshift {var} {
          upvar 1 $var x
          set r [lindex $x 0]
          set x [lrange $x 1 end]
          return $r
        }


        proc lfront {list} {
          return [lindex $list 0]
        }


        rename puts ::tcl::puts


        proc puts {args} {
          variable stdout
          variable stderr
          set xargs $args
          if {[llength $args] > 1 && [lfront $args] == "-nonewline"} {
            lshift args
            set newline 0
          } else {
            set newline 1
          }
          switch [llength $args] {
            1 {set chan stdout}
            default {set chan [lshift args]}
          }
          if {$chan == "stdout" || $chan == "stderr"} {
            if {$newline} {
              lappend $chan $args
            } else {
              set $chan [concat [lrange [set $chan] 0 end-1] "[lindex [set $chan] end]$args"]
            }
          } else {
            tcl::puts {*}$xargs
          }
        }


        proc execute {code} {
          variable stdout [list]
          variable stderr [list]
          interp create unit
          try {
            interp alias unit puts {} puts
            catch {unit eval $code} return opts
            return [dict merge $opts [dict create -return $return -stdout $stdout -stderr $stderr]]
          } finally {
            interp delete unit
          }
        }


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
        lappend pending [tpool::post $executor "execute {$code}"]
      }


      Import $argv0


      puts "TAP version 14"
      puts "1..[dict size $units]"


      while {[llength $pending]} {
        set finished [tpool::wait $executor $pending pending]
        foreach f $finished {
          set pending [lsearch -inline -all -not -exact $pending $f]
          set name [dict get [dict get $units $f] -name]
          set return [tpool::get $executor $f]
          if {[dict get $return -code] == 0} {
            puts "ok - $name"
          } else {
            puts "not ok - $name"
            puts "  ---"
            puts "  return: [dict get $return -return]"
            puts "  ..."
          }
          puts stderr {}
          puts stderr "# $name"
          set lines [dict get $return -stdout]
          if {[llength $lines] > 0} {
            puts stderr "## stdout:"
            foreach line $lines {puts stderr $line}
          }
          set lines [dict get $return -stderr]
          if {[llength $lines] > 0} {
            puts stderr "## stderr:"
            foreach line $lines {puts stderr $line}
          }
        }
      }


      exit 0


    } on error {result opts} {
      puts stderr [dict get $opts -errorinfo]
      puts "Bail out!"
      exit 1
    }


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