# buildme - staging directories & external command execution for the testme units
# https://github.com/okhlybov/testme


package require Tcl 8.6-


namespace eval ::buildme {


  namespace export sandbox shell SpawnWatchdog


  # The staging directory in effect for the buildme commands;
  # empty when no sandbox is active
  variable stage {}


  # The unit record accessor; empty answers when buildme runs
  # outside of a testme unit
  proc Field {key} {
    if {[catch {unit $key} value]} {return {}}
    return $value
  }


  proc MakeTempDir {args} {
    set roots $args
    foreach var {TMPDIR TMP} {
      if {[info exists ::env($var)]} {
        lappend roots $::env($var)
      }
    }
    lappend roots /tmp
    # The prefix carries the defining suite name together with the unit id,
    # so the concurrent units of one suite never share a draw
    set prefix buildme
    set source [Field -source]
    if {$source ne {}} {
      set prefix "[file rootname [file tail $source]]-[Field -id]"
    }
    set dir ""
    foreach r $roots {
      set dir [file join $r $prefix.[expr {int(rand()*999999)}]]
      if {![catch {file mkdir $dir}]} {return $dir}
    }
    error "failed to create temporary directory $dir"
  }


  proc MakeWritable {dir} {
    catch {file attributes $dir -permissions 0755}
    catch {file attributes $dir -readonly 0}
    foreach item [glob -nocomplain -directory $dir * .*] {
      set tail [file tail $item]
      if {$tail eq "." || $tail eq ".."} continue
      set ftype ""
      catch {set ftype [file type $item]}
      if {[file isdirectory $item] && $ftype ne "link"} {
        MakeWritable $item
      } else {
        catch {file attributes $item -permissions 0644}
        catch {file attributes $item -readonly 0}
      }
    }
  }


  # Spawns a background watchdog to periodically retry deleting locked directories (e.g. on Windows)
  proc SpawnWatchdog {dir {timeout 60}} {
    if {![file exists $dir]} return
    set tempDir [file dirname [file normalize $dir]]
    set script [file join $tempDir "watchdog-[pid]-[expr {int(rand()*999999)}].tcl"]
    if {[catch {
      set f [open $script w]
      puts $f {
        proc MakeWritable {dir} {
          catch {file attributes $dir -permissions 0755}
          catch {file attributes $dir -readonly 0}
          foreach item [glob -nocomplain -directory $dir * .*] {
            set tail [file tail $item]
            if {$tail eq "." || $tail eq ".."} continue
            set ftype ""
            catch {set ftype [file type $item]}
            if {[file isdirectory $item] && $ftype ne "link"} {
              MakeWritable $item
            } else {
              catch {file attributes $item -permissions 0644}
              catch {file attributes $item -readonly 0}
            }
          }
        }
        set target [lindex $argv 0]
        set timeout 60
        if {[llength $argv] > 1 && [string is integer -strict [lindex $argv 1]]} {
          set timeout [lindex $argv 1]
        }
        set deadline [expr {[clock seconds] + $timeout}]
        try {
          while {[file exists $target] && [clock seconds] < $deadline} {
            after 500
            catch { MakeWritable $target }
            catch { file delete -force -- $target }
          }
        } finally {
          catch { file delete -force -- [info script] }
        }
      }
      close $f
      exec [info nameofexecutable] $script $dir $timeout &
    } err]} {
      catch {file delete -force -- $script}
    }
  }


  # Creates a staging directory seeded with the contents of the unit's origin
  # (the directory of the suite defining the unit), evaluates the code with
  # the staging directory in effect for the subsequent buildme commands,
  # then removes the directory unless the run keeps its garbage (-K)
  proc sandbox {code} {
    variable stage
    set dir [MakeTempDir]
    set saved $stage
    try {
      set seed $stage
      if {$seed eq {}} {
        set seed [Field -origin]
        if {$seed eq {}} { set seed [Field -stage] }
      }
      if {$seed ne {} && [file isdirectory $seed]} {
        foreach p [lsort -unique [glob -nocomplain -directory $seed * .*]] {
          set last [file tail $p]
          if {$last eq "." || $last eq ".."} continue
          catch {file type $p} ftype
          if {$ftype in {file directory link}} {
            catch {file copy -force -- $p $dir}
          }
        }
        # Ensure the staged files and directories are user-writable even when
        # the suite was located in a read-only filesystem
        MakeWritable $dir
      }
      # The stage cannot be entered with cd in a multithreaded environment
      # where all the threads share one current directory
      set stage $dir
      uplevel 1 $code
    } finally {
      set stage $saved
      if {[Field -cleanup] ne {false}} {
        MakeWritable $dir
        if {[catch {file delete -force -- $dir}]} {
          SpawnWatchdog $dir
        }
      }
    }
  }


  proc shell {cmd} {
    variable stage
    if {$stage eq {}} { set stage [Field -stage] }
    set sh "/bin/sh"
    set flag "-c"
    if {[info exists ::env(SHELL)] && $::env(SHELL) ne {}} {
      set sh $::env(SHELL)
    } elseif {$::tcl_platform(platform) eq "windows"} {
      set sh [expr {[info exists ::env(COMSPEC)] ? $::env(COMSPEC) : "cmd.exe"}]
      set flag "/c"
    }
    set nativeStage [file nativename $stage]
    set cd [expr {$flag eq "/c" ? "cd /d $nativeStage" : "cd \"$stage\""}]
    puts stdout "$cd && \\\n$cmd"
    if {[catch {exec -ignorestderr $sh $flag "$cd && $cmd" 2>@1} result opts]} {
      puts stderr $result
    } else {
      puts stdout $result
    }
    return {*}$opts $result
  }


}
