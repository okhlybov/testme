# shellme - staging, shell & program I/O isolation for the testme units
# https://github.com/okhlybov/testme


package require Tcl 8.6-
package provide shellme 0


namespace eval ::shellme {


  namespace export unit sandbox shell stage


  # The staging directory in effect for the shellme commands;
  # empty when no sandbox is active
  variable stage {}


  # The current staging directory (falls back to the unit's own stage)
  proc stage {} {
    variable stage
    if {$stage ne {}} {return $stage}
    return [Field -stage]
  }


  # The unit record accessor; empty answers when shellme runs
  # outside of a testme unit. The accessor is invoked by its absolute
  # name: a bare `unit` would resolve to ::shellme::unit right in this
  # namespace (the suite-level specification wrapper) and loop forever
  proc Field {key} {
    if {[catch {::unit $key} value]} {return {}}
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
    set prefix shellme
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


  # Escapes a path for the POSIX single quoting: an embedded quote closes
  # the string, escapes itself and reopens it
  proc shellquote {path} {
    regsub -all {'} $path {'\\''} path
    return "'$path'"
  }


  # The best effort process tree termination: the shell runs in a session of
  # its own whenever setsid exists, so the whole tree shares the process
  # group of the root pid; elsewhere (or on Windows) the pid itself is the
  # best available target
  proc KillTree {pids} {
    foreach pid $pids {
      if {$::tcl_platform(platform) eq "windows"} {
        catch {exec taskkill /PID $pid /T /F}
      } elseif {[catch {exec kill -TERM -- -$pid}]} {
        catch {exec kill -TERM -- $pid}
      }
    }
  }


  # Creates a staging directory seeded with (a selection of) the unit origin
  # (the directory of the suite defining the unit), evaluates the code with
  # the staging directory in effect for the subsequent shellme commands,
  # then removes the directory unless the run keeps its garbage (-K)
  proc sandbox {args} {
    variable stage
    # shellme::sandbox ?-seed dir? ?-exclude patterns? ?-only paths? ?--? code
    set seed {}
    set exclude {.git .hg .svn CVS _darcs}
    set only {}
    while {[llength $args] > 1} {
      set a [lindex $args 0]
      if {$a eq {-seed} || $a eq {-exclude} || $a eq {-only}} {
        if {[llength $args] < 3} {
          error "usage: shellme::sandbox ?-seed dir? ?-exclude patterns? ?-only paths? ?--? code"
        }
        switch -- $a {
          -seed {set seed [lindex $args 1]}
          -exclude {set exclude [lindex $args 1]}
          -only {set only [lindex $args 1]}
        }
        set args [lrange $args 2 end]
      } elseif {$a eq {--}} {
        set args [lrange $args 1 end]
        break
      } else {
        break
      }
    }
    if {[llength $args] != 1} {
      error "usage: shellme::sandbox ?-seed dir? ?-exclude patterns? ?-only paths? ?--? code"
    }
    set code [lindex $args 0]
    set dir [MakeTempDir]
    set saved $stage
    try {
      if {$seed eq {}} {
        set seed $stage
        if {$seed eq {}} {
          set seed [Field -origin]
          if {$seed eq {}} {set seed [Field -stage]}
        }
      }
      if {$seed ne {} && [file isdirectory $seed]} {
        if {[llength $only] > 0} {
          # just the named paths, parent directories created as needed
          foreach p $only {
            set src [file join $seed $p]
            if {![file exists $src]} {continue}
            catch {file mkdir [file dirname [file join $dir $p]]}
            catch {file copy -force -- $src [file join $dir $p]}
          }
        } else {
          foreach p [lsort -unique [glob -nocomplain -directory $seed * .*]] {
            set last [file tail $p]
            if {$last eq "." || $last eq ".."} continue
            set skip 0
            foreach pat $exclude {
              if {[string match $pat $last]} {set skip 1; break}
            }
            if {$skip} continue
            catch {file type $p} ftype
            if {$ftype in {file directory link}} {
              catch {file copy -force -- $p $dir}
            }
          }
        }
        # Ensure the staged files and directories are user-writable even when
        # the suite was located in a read-only filesystem
        MakeWritable $dir
      }
      # The timeout fallback: a timed out unit cannot run its own cleanup,
      # so the sandbox removal is registered worker-side as well
      if {[Field -cleanup] ne {false}} {
        catch {::testme::AtEnd [list file delete -force -- $dir]}
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


  # Executes a shell command in the active sandbox (or the unit's stage).
  # The shell is /bin/sh (or %COMSPEC% on Windows) unless SHELLME_SHELL
  # or the -shell option says otherwise; $SHELL is deliberately ignored:
  # an interactive shell of the day is no foundation for tests.
  # The output is returned (and echoed to the unit channels); a non-zero
  # exit raises an error carrying the output; -timeout aborts and kills
  # the whole command tree
  proc shell {args} {
    variable stage
    if {$stage eq {}} { set stage [Field -stage] }
    set timeout 0
    set shprog {}
    while {[llength $args] > 1} {
      set a [lindex $args 0]
      if {$a eq {-timeout} || $a eq {-shell}} {
        if {[llength $args] < 3} {
          error "usage: shellme::shell ?-timeout seconds? ?-shell program? ?--? command"
        }
        if {$a eq {-timeout}} {
          set timeout [lindex $args 1]
        } else {
          set shprog [lindex $args 1]
        }
        set args [lrange $args 2 end]
      } elseif {$a eq {--}} {
        set args [lrange $args 1 end]
        break
      } else {
        break
      }
    }
    if {[llength $args] != 1} {
      error "usage: shellme::shell ?-timeout seconds? ?-shell program? ?--? command"
    }
    set cmd [lindex $args 0]
    if {$shprog eq {}} {
      if {[info exists ::env(SHELLME_SHELL)] && $::env(SHELLME_SHELL) ne {}} {
        set shprog $::env(SHELLME_SHELL)
      } elseif {$::tcl_platform(platform) eq "windows"} {
        set shprog [expr {[info exists ::env(COMSPEC)] ? $::env(COMSPEC) : "cmd.exe"}]
      } else {
        set shprog /bin/sh
      }
    }
    # cmd.exe takes /c and cd /d; every sh flavor takes -c
    set cmdlike [string match cmd* [string tolower [file tail $shprog]]]
    if {$cmdlike} {
      set flag /c
      # Windows paths cannot carry the double quote, so the quoting is safe
      set script "cd /d [file nativename $stage] && $cmd"
    } else {
      set flag -c
      set script "cd [shellquote $stage] && $cmd"
    }
    # A session of its own keeps the whole command tree killable as a group
    set launcher {}
    if {!$cmdlike && ![catch {auto_execok setsid} bin] && $bin ne {}} {
      set launcher $bin
    }
    set words [list $shprog $flag $script]
    if {$launcher ne {}} {
      set words [linsert $words 0 $launcher]
    }
    lappend words 2>@1
    set chan [open |$words r]
    fconfigure $chan -blocking 0
    set pids [pid $chan]
    catch {::testme::RegisterPids $pids}
    set out {}
    set timedout 0
    set deadline [expr {$timeout > 0 ? [clock milliseconds] + int($timeout * 1000) : 0}]
    while {1} {
      append out [read $chan]
      if {[eof $chan]} {break}
      if {$deadline && [clock milliseconds] >= $deadline} {
        set timedout 1
        break
      }
      after 20
    }
    if {$timedout} {
      KillTree $pids
      catch {::testme::UnregisterPids $pids}
      catch {close $chan}
      error "shellme: command timed out after $timeout s; partial output:\n$out"
    }
    # A blocking close waits for the child and reports its exit status;
    # a non-blocking one would silently discard it
    fconfigure $chan -blocking 1
    set rc [catch {close $chan} cerr copts]
    catch {::testme::UnregisterPids $pids}
    set out [string trimright $out \n]
    if {$rc} {
      puts stderr $out
      return {*}$copts $out
    }
    puts stdout $out
    return {*}$copts $out
  }


  # The program I/O capture for the unit layer: the process stream
  # redirections of exec are rerouted into temporary files, and the collected
  # bytes are fed into the unit's basic output tally afterwards. The wrapper
  # chains onto the runner's deny layer: after the rewrite no stream
  # redirections remain, so everything reaches the real exec verbatim
  proc InstallExecCapture {} {
    if {[llength [info commands ::shellme::PrevExec]] == 0} {
      rename ::exec ::shellme::PrevExec
    }
    set ::shellme::execTmp [dict create]
    proc ::shellme::TempOf {chan} {
      if {![dict exists $::shellme::execTmp $chan]} {
        set f [file tempfile path]
        close $f
        dict set ::shellme::execTmp $chan $path
      }
      return [dict get $::shellme::execTmp $chan]
    }
    proc ::exec {args} {
      set argv $args
      set background [expr {[lindex $argv end] eq "&"}]
      if {$background} {set argv [lrange $argv 0 end-1]}
      set rewritten {}
      set touched 0
      set n [llength $argv]
      for {set i 0} {$i < $n} {incr i} {
        set w [lindex $argv $i]
        set op {}
        set chan {}
        if {[regexp {^(2>@|>&@|>@)(stdout|stderr)$} $w -> op chan]} {
          set op [string range $op 0 end-1]
        } elseif {($w eq {>@} || $w eq {2>@} || $w eq {>&@})
                  && [lindex $argv [expr {$i + 1}]] in {stdout stderr}} {
          set chan [lindex $argv [expr {$i + 1}]]
          set op [string range $w 0 end-1]
          incr i
        }
        if {$chan ne {}} {
          if {$background} {
            return -code error "shellme: stream redirection is unsupported for background commands"
          }
          lappend rewritten "$op[::shellme::TempOf $chan]"
          set touched 1
        } else {
          lappend rewritten $w
        }
      }
      if {$background} {lappend rewritten &}
      if {!$touched} {
        tailcall ::shellme::PrevExec {*}$rewritten
      }
      set rc [catch {::shellme::PrevExec {*}$rewritten} res opts]
      foreach {chan path} $::shellme::execTmp {
        catch {
          set f [open $path rb]
          try {
            set data [read $f]
            puts -nonewline $chan [encoding convertfrom [chan configure $chan -encoding] $data]
          } finally {
            close $f
          }
        }
        catch {file delete -force -- $path}
      }
      set ::shellme::execTmp [dict create]
      return {*}$opts $res
    }
  }


  # The unit specification: submits through the suite's own unit command
  # (all the usual options - name, tags, skip, todo, timeout, subtest,
  # custom pass-throughs - travel verbatim) and wraps the body in a fully
  # configured environment: a seeded staging sandbox, the shell targeting
  # it, captured program I/O. The body can test files and run external
  # programs right away
  proc unit {args} {
    set nargs [llength $args]
    if {$nargs < 1 || $nargs % 2 == 0} {
      error "usage: shellme::unit ?-name ...? ?-tags ...? ?-skip ...? ?-todo ...? ?-timeout N? ?-seed dir? ?-exclude patterns? ?-only paths? ?-staging auto|none? ?anything ...? {code...}"
    }
    set opts [lrange $args 0 end-1]
    set body [lindex $args end]
    set seed {}
    set exclude {.git .hg .svn CVS _darcs}
    set only {}
    set staging auto
    set rest [list]
    foreach {k v} $opts {
      switch -- $k {
        -seed {set seed $v}
        -exclude {set exclude $v}
        -only {set only $v}
        -staging {set staging $v}
        default {lappend rest $k $v}
      }
    }
    if {$staging ni {auto none}} {
      error "shellme::unit: -staging must be auto or none, got \"$staging\""
    }
    if {$staging eq {none}} {
      # no sandbox: the program I/O capture still applies
      set wrapped [list apply [list body {
        package require shellme
        ::shellme::InstallExecCapture
        uplevel 1 $body
      }] $body]
    } else {
      set wrapped [list apply [list {body seed exclude only} {
        package require shellme
        ::shellme::sandbox -seed $seed -exclude $exclude -only $only {
          ::shellme::InstallExecCapture
          uplevel 1 $body
        }
      }] $body $seed $exclude $only]
    }
    uplevel 1 [concat [list ::unit] $rest [list $wrapped]]
  }


}
