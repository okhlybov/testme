# testme - a testing pico framework for Tcl
# https://github.com/okhlybov/testme


package require Tcl


namespace eval ::buildme {
  

  namespace export sandbox shell


  proc MakeTempDir {args} {
    upvar 1 unit unit
    set roots $args
    foreach var {TMPDIR TMP} {
      if {[info exists ::env($var)]} {
        lappend roots $::env($var)
      }
    }
    lappend roots /tmp
    set prefix "buildme"
    if {[info exists unit] && [dict exists $unit -source]} {
      set prefix [file rootname [file tail [dict get $unit -source]]]
    }
    set dir ""
    foreach r $roots {
      set dir [file join $r $prefix.[expr {int(rand()*999999)}]]
      if {![catch {file mkdir $dir}]} {return $dir}
    }
    error "failed to create temporary directory $dir"
  }


  proc sandbox {code} {
    upvar 1 unit unit
    set dir [MakeTempDir]
    try {
      if {[info exists unit] && [dict exists $unit -stage]} {
        foreach p [lsort -unique [glob -nocomplain -directory [dict get $unit -stage] * .*]] {
          set last [lindex [file split $p] end]
          if {$last != "." && $last != ".."} {
            file copy -force -- $p $dir
          }
        }
      }
      # Can't cd into stage dir in multithreaded environment where all threads have the same current directory
      if {[info exists unit]} {dict set unit -stage $dir}
      uplevel 1 $code
    } finally {
      if {![info exists unit] || ![dict exists $unit -cleanup] || [dict get $unit -cleanup]} {
        if {[catch {file delete -force -- $dir}]} {
          puts stderr "failed to delete temporary directory $dir"
        }
      }
    }
  }


  proc shell {cmd} {
    upvar 1 unit unit
    set stage [dict get $unit -stage]
    set cd "cd \"$stage\""
    puts stdout "$cd && \\\n$cmd"
    if {[catch {exec -ignorestderr $::env(SHELL) -c "$cd && $cmd" 2>@1} result opts]} {
      puts stderr $result
    } else {
      puts stdout $result
    }
    return {*}$opts $result
  }


}