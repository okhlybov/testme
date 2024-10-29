# https://github.com/okhlybov/testme


package require Tcl 8.6


namespace eval ::buildme {
  

  namespace export sandbox system


  proc MakeTempDir {args} {
    set roots $args
    foreach t {TMPDIR TMP} {
      if {![catch {set t [set ::env($t)]}]} {
        lappend roots $t
      }
    }
    lappend roots /tmp
    foreach r $roots {
      if {![catch {
        set prefix [file rootname [file tail [info script]]]
        if {$prefix == {}} {set prefix tmp}
        set t [file join $r $prefix.[expr {int(rand()*999999)}]]
        file mkdir $t
      }]} {
        return $t
      }
    }
    error "failed to create temporary directory $t"
  }


  proc sandbox {code} {
    set dir [MakeTempDir]
    puts [info script]
    try {
      set wd [pwd]
      try {
        foreach p [glob -nocomplain * .*] {
          if {$p != {.} && $p != {..}} {
            file copy -force -- $p $dir
          }
        }
        cd $dir
        eval $code
      } finally {
        cd $wd
      }
    } finally {
      if {[catch {file delete -force -- $dir}]} {
        puts stderr "failed to delete temporary directory $dir
      }
    }
  }


  proc system {cmd} {
    puts stdout $cmd
    if {[catch {exec -ignorestderr $::env(SHELL) -c $cmd 2>@1} result opts]} {
      puts stderr $result
    } else {
      puts stdout $result
    }
    return {*}$opts $result
  }


}