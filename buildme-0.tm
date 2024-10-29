# https://github.com/okhlybov/testme


package require Tcl 8.6


namespace eval ::buildme {
  

  namespace export sandbox system



  proc mktmpdir {args} {
    set roots $args
    foreach t {TMPDIR TMP} {
      if {![catch {set t [set ::env($t)]}]} {
        lappend roots $t
      }
    }
    lappend roots /tmp
    foreach r $roots {
      if {![catch {
        set t [file join $r [file rootname [file tail [info script]]].[expr {int(rand()*999999)}]]
        file mkdir $t
      }]} {
        return $t
      }
    }
    error "failed to create temporary directory $t"
  }


  proc rmdir {dir} {
    file delete -force -- $dir
  }


  proc sandbox {code} {
    set dir [mktmpdir]
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
      rmdir $dir
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