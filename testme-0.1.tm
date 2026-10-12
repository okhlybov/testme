# testme - a testing pico framework for Tcl
# https://github.com/okhlybov/testme


package require Tcl 8.6-


if {[catch {package present Thread}] && [catch {package present thread}] &&
    ![llength [package versions Thread]] && ![llength [package versions thread]]} {
  set found ""
  if {[info exists ::env(TESTME_THREAD_DIR)] && [file isfile [file join $::env(TESTME_THREAD_DIR) pkgIndex.tcl]]} {
    set found $::env(TESTME_THREAD_DIR)
  } else {
    foreach base [list [info library] [file dirname [info library]]] {
      foreach c [glob -nocomplain -directory $base -types d *thread*] {
        if {[file isfile [file join $c pkgIndex.tcl]]} {
          set found $c
          break
        }
      }
      if {$found ne ""} {break}
    }
  }
  if {$found ne ""} {
    set dir $found
    catch {source [file join $found pkgIndex.tcl]}
    set ::env(TESTME_THREAD_DIR) $found
  }
}
package require Thread


namespace eval ::testme {


  variable version
  regexp -- {-(\d+(?:\.\d+)*)$} [file rootname [file tail [info script]]] ~ version


  # The inter-level protocol record; see HACKING.md. Extending it takes adding a field right here
  variable fields {
    ancestors {}
    bailout false
  }


  namespace export unit


  proc Import {source {path {}}} {
    variable executor
    variable version
    variable seq
    variable fields
    set norm [file normalize $source]
    if {$path eq {}} {set path [concat $::ancestors [list $norm]]}
    set ::ancestors $path
    set box box[incr seq]
    interp create $box
    try {
      $box eval {
        rename exit {}
        proc exit {args} {
          if {[llength $args]} {
            return -code error "the suite code requested to terminate the process: exit $args"
          }
          return -code error {the suite code requested to terminate the process: exit}
        }
      }
      interp alias $box ::testme::unit {} ::testme::unit
      interp alias $box ::testme::nest {} ::testme::Nest
      interp alias $box ::testme::DetectCores {} ::testme::DetectCores
      $box eval {namespace eval ::testme {namespace export unit DetectCores}}
      $box eval set ::argv0 $norm
      $box eval [list set ::ancestors $path]
      foreach {name default} $fields {
        if {$name eq {ancestors}} {continue}
        if {[info exists ::$name]} {
          $box eval [list set ::$name [set ::$name]]
        } else {
          $box eval [list set ::$name $default]
        }
      }
      $box eval [list package ifneeded testme $version "[list ::testme::nest [file dirname $norm] $path]; [list package provide testme $version]"]
      $box eval {
        cd [file dirname $::argv0]
        source [file tail $::argv0]
      }
    } finally {
      interp delete $box
    }
  }


  # Nested suite lookup & processing; runs on the driving interpreter of the enclosing level
  proc Nest {dir {path {}}} {
    set wd [pwd]
    foreach source [glob -nocomplain -directory $dir [file join * [file tail $::argv0]]] {
      set norm [file normalize [string range $source 0 end]]
      if {[lsearch -exact $path $norm] >= 0} {continue}
      try {
        Import $source [linsert $path end $norm]
      } on error {e o} {
        # Contain the failure unless bailing out is requested
        if {[info exists ::bailout] && $::bailout} {
          return -code error -errorinfo [dict get $o -errorinfo] $e
        }
        FailSuite $source $e
      } finally {cd $wd}
    }
  }


  proc DetectCores {} {
    if {[info exists ::env(TESTME_JOBS)] && [string is integer -strict $::env(TESTME_JOBS)] && $::env(TESTME_JOBS) > 0} {
      return $::env(TESTME_JOBS)
    }
    if {[info exists ::env(NUMBER_OF_PROCESSORS)] && [string is integer -strict $::env(NUMBER_OF_PROCESSORS)] && $::env(NUMBER_OF_PROCESSORS) > 0} {
      return $::env(NUMBER_OF_PROCESSORS)
    }
    if {[file readable /sys/devices/system/cpu/online]} {
      if {![catch {
        set f [open /sys/devices/system/cpu/online r]
        try {
          set line [string trim [read $f]]
        } finally {
          close $f
        }
        set count 0
        foreach range [split $line ,] {
          if {[regexp {^(\d+)-(\d+)$} $range ~ start end]} {
            incr count [expr {$end - $start + 1}]
          } elseif {[string is integer -strict $range]} {
            incr count
          }
        }
        if {$count > 0} {return $count}
      }]} {}
    }
    if {[file readable /proc/cpuinfo]} {
      if {![catch {
        set f [open /proc/cpuinfo r]
        try {
          set data [read $f]
        } finally {
          close $f
        }
        set count [llength [regexp -all -line -inline {^processor\s*:} $data]]
        if {$count > 0} {return $count}
      }]} {}
    }
    foreach sysctl_cmd {{sysctl -n hw.logicalcpu} {sysctl -n hw.ncpu}} {
      if {![catch {exec {*}$sysctl_cmd} n] && [string is integer -strict $n] && $n > 0} {
        return $n
      }
    }
    foreach cmd {{nproc} {getconf _NPROCESSORS_ONLN}} {
      if {![catch {exec {*}$cmd} n] && [string is integer -strict $n] && $n > 0} {
        return $n
      }
    }
    return 4
  }


  ### Toplevel code


  # The layer discriminator: the driver plants the protocol record
  # (::ancestors) in every child it imports; a bare load finds no record
  # and runs the driver instead
  try {set ::ancestors} on error {} {


    if {![info exists ::argv0] || $::argv0 eq {} ||
        [file normalize $::argv0] eq [file normalize [info nameofexecutable]] ||
        ![file isfile [file normalize $::argv0]]} {
      error {testme must be required by a test suite script being executed (invalid ::argv0)}
    }


    variable verbose false
    variable full false
    variable quiet false
    variable staging false
    variable premature false
    variable cleanup true
    variable jobs 0
    variable failures 0


    try {


      package require clip


      set opts {
        {{--jobs= -j=} -info "set maximum number of allowed threads" -default 0 -slot jobs}
        {{-v --verbose} -info "dump unit output to standard error channel" -default true -slot verbose}
        {{-F --full-dump} -info "dump unit output for succeeded tests as well" -default true -slot full}
        {{-T --staging} -info "manage staging directory in \$TMPDIR" -default true -slot staging}
        {{-K --keep} -info "keep temporary directories & files" -default false -slot cleanup}
        {{-e --bailout} -info "bail out on first failure" -default true -slot premature}
        {{-q --quiet} -info "suppress TAP output to standard output channel" -default true -slot quiet}
        {{-h --help} -info "print help" -apply {
          puts stderr "usage: $::argv0 {-f --flag --opt=arg --opt arg -opt arg ...} {--} {tag +tag -tag ...}"
          puts stderr {}
          puts stderr "    +tag | tag    instruct to execute only units with specified tag(s)"
          puts stderr "    -tag          instruct to skip units with specified tag(s)"
          clip::usage $testme::opts {} stderr
          exit 0
        }}
        {{--version} -info "print package version" -apply {
          puts stderr [package require testme]
          exit 0
        }}
      }


      if {[catch {
        if {[llength $::argv]} {set ::argv [clip::parse $::argv $opts]}
      } return]} {
        puts stderr $return
        exit 1
      }


      if {$jobs == 0} {
        set jobs [DetectCores]
      }


      set +tags [list]
      set -tags [list]


      foreach arg $::argv {
        switch -glob $arg {
          +* {lappend +tags [string trimleft $arg +]}
          -* {lappend -tags [string trimleft $arg -]}
          default {lappend +tags $arg}
        }
      }


      variable fields
      foreach {name default} $fields {
        if {![info exists ::$name]} {set ::$name $default}
      }


      set ::bailout $premature


      # The tapme consumer is loaded only when the TAP output is not requested
      variable tapme false
      if {$quiet} {set tapme [expr {![catch {package require tapme}]}]}


      set paths "eval tcl::tm::path add [tcl::tm::path list]"


      set static {


        ### Execution thread code


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


        # The unit context accessor: nested retrieval of the unit record
        proc Context {args} {
          if {![llength $args]} {return $::testme::Context}
          tailcall dict get $::testme::Context {*}$args
        }


        proc Puts {args} {
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
              foreach arg $args {lappend $chan $arg}
            } else {
              set $chan [concat [lrange [set $chan] 0 end-1] "[lindex [set $chan] end]$args"]
            }
          } else {
            tcl::puts {*}$xargs
          }
        }


        proc Skip {{reason {}}} {return -code 1073741823 -level 0 $reason}


        proc process {unit} {
          variable stdout [list]
          variable stderr [list]
          set ::testme::Context $unit
          interp create unit
          try {
            unit eval {
              rename exit {}
              proc exit {args} {
                if {[llength $args]} {
                  return -code error "the unit code requested to terminate the process: exit $args"
                }
                return -code error {the unit code requested to terminate the process: exit}
              }
            }
            interp alias unit CapturePuts {} Puts
            unit eval {
              rename puts ::tcl::puts
              proc puts {args} {
                set xargs $args
                if {[llength $args] > 1 && [lindex $args 0] eq "-nonewline"} {
                  set rest [lrange $args 1 end]
                } else {
                  set rest $args
                }
                set chan [expr {[llength $rest] == 1 ? "stdout" : [lindex $rest 0]}]
                if {$chan eq "stdout" || $chan eq "stderr"} {
                  CapturePuts {*}$xargs
                } else {
                  ::tcl::puts {*}$xargs
                }
              }
            }
            interp alias unit skip {} Skip
            interp alias unit context {} Context
            # The unit layer facade: the auxiliary helpers without the driving machinery
            unit eval [list package ifneeded testme $::testme::version [list package provide testme $::testme::version]]
            unit eval {
              namespace eval ::testme {namespace export with}
              proc ::testme::with {var list code} {
                upvar 1 $var v
                if {[catch {set v}]} {set v [list]}
                set list [concat $v $list]
                apply [list $var $code] $list
              }
            }
            unit eval tcl::tm::path add {*}[tcl::tm::path list]
            catch {unit eval "apply {{unit} {[dict get $unit -code]}} {$unit}"} return opts
            return [dict merge $opts [dict create -return $return -stdout $stdout -stderr $stderr -id [dict get $unit -id]]]
          } finally {
            interp delete unit
          }
        }


      }


      variable executor [tpool::create -maxworkers $jobs -initcmd "$paths; [list namespace eval ::testme [list set version $version]]; $static;"]


      variable pending [list]


      variable skipped [list]


      variable synthetic [list]


      variable units [dict create]


      variable id 1


      proc union {as bs} {
        set result $as
        foreach elem $bs {
          if {[lsearch -exact $as $elem] == -1} {
            lappend result $elem
          }
        }
        return $result
      }


      proc intersection {as bs} {
        set result {}
        foreach elem $bs {
          if {[lsearch -exact $as $elem] >= 0} {
            lappend result $elem
          }
        }
        return $result
      }


      proc unit {args} {
        variable executor
        variable pending
        variable skipped
        variable units
        variable +tags
        variable -tags
        variable cleanup
        variable id
        set s [llength $args]
        if {$s < 1 || $s % 2 == 0} {error "usage: testme::unit ?-name ...? ?-tags ...? {...}"}
        set opts [lrange $args 0 end-1]
        set code [lindex [lrange $args end end] 0]
        set name unit[llength $pending]
        set tags [list]
        catch {set name [dict get $opts -name]}
        catch {set tags [dict get $opts -tags]}
        set tags [lsearch -inline -all -not -exact $tags {}]; # Squeeze out empty {} tags
        set unit [dict create {*}$opts -stage [pwd] -name $name -tags $tags -code $code -id $id -source $::argv0 -cleanup $cleanup]
        dict set units $id $unit
        if {([llength ${+tags}] == 0 || [llength [intersection ${+tags} $tags]] > 0) && [llength [intersection ${-tags} $tags]] == 0} {
          lappend pending [tpool::post $executor "process {$unit}"]
        } else {
          lappend skipped $id
        }
        incr id
      }


      # Emits a TAP line: prints it, or feeds the suppressed output to the tapme consumer
      proc Emit {text} {
        variable quiet
        variable tapme
        if {$quiet} {
          if {$tapme} {::tapme::line $text}
        } else {
          puts $text
        }
      }


      # Registers a failed nested suite as a synthetic failed unit, keeping the TAP plan consistent
      proc FailSuite {source info} {
        variable units
        variable id
        variable synthetic
        dict set units $id [dict create -name "suite $source" -tags [list] -id $id -source $source]
        lappend synthetic [dict create -code 1 -return $info -stdout [list] -stderr [list] -id $id]
        incr id
      }


      # Reports a single unit result: TAP line, verbose channels dump, log files
      proc Report {return} {
        variable units
        variable quiet
        variable tapme
        variable verbose
        variable full
        variable cleanup
        variable staging
        variable origin
        variable failures
        variable premature
        set u [dict get $units [dict get $return -id]]
        set name [dict get $u -name]
        set id [dict get $u -id]
        switch [dict get $return -code] {
          0 {set outcome succeeded}
          1073741823 {set outcome skipped}
          default {set outcome failed}
        }
        if {$outcome eq {failed}} {incr failures}
        if {!$quiet || $tapme} {
          switch $outcome {
            succeeded {Emit "ok $id - $name"}
            skipped {Emit "ok $id - $name # SKIP [dict get $return -return]"}
            failed {
              Emit "not ok $id - $name"
              Emit "  ---"
              set lines [split [dict get $return -return] "\n"]
              set r [lindex $lines 0]
              if {[llength $lines] > 1} {set r "$r >>>"}
              Emit "  tags: [dict get $u -tags]"
              Emit "  source: [dict get $u -source]"
              Emit "  return: $r"
              Emit "  ..."
            }
          }
        }
        if {$verbose && ($full || $outcome eq {failed})} {
          set stdout [dict get $return -stdout]
          set stderr [dict get $return -stderr]
          if {[llength $stdout] + [llength $stderr] > 0} {
            puts stderr {}
            puts stderr "- $name"
            if {[llength $stdout] > 0} {
              puts stderr "-- stdout:"
              foreach line $stdout {puts stderr $line}
            }
            if {[llength $stderr] > 0} {
              puts stderr "-- stderr:"
              foreach line $stderr {puts stderr $line}
            }
          }
        }
        flush stdout
        flush stderr
        if {!$cleanup} {
          # Dumping channels contents into per-unit log files for post-mortem inspection
          if {$staging ne {false}} {set logs $staging} else {set logs $origin}
          set tag $name
          regsub -all {\W} $tag {_} tag
          foreach x {stdout stderr} {
            set s [dict get $return -$x]
            if {[llength $s] > 0} {
              try {
                set f [open [file join $logs "$id-$tag-$x.out"] w]
                try {
                  foreach t $s {puts $f $t}
                } finally {
                  close $f
                }
              }
            }
          }
        }
        if {$premature && $outcome eq {failed}} {error "bailing out on failure"}
      }


      if {$staging} {


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
              set t [file join $r [expr {int(rand()*999999)}]]
              file mkdir $t
            }]} {
              return $t
            }
          }
          error "failed to create temporary directory $t"
        }  


        set staging [set ::env(TMPDIR) [MakeTempDir]]


        if {$verbose} {puts stderr "created temporary directory $staging"}

      }


      set origin [pwd]


      try {


        Import $::argv0 [list [file normalize $::argv0]]


        if {!$quiet || $tapme} {
          Emit "TAP version 14"
          Emit "1..[dict size $units]"
          foreach s $skipped {
            set u [dict get $units $s]
            Emit "ok [dict get $u -id] - [dict get $u -name] # SKIP due to tagging"
          }
        }


        while {[llength $pending]} {
          foreach f [tpool::wait $executor $pending pending] {
            set pending [lsearch -inline -all -not -exact $pending $f]
            Report [tpool::get $executor $f]
          }
        }
        foreach s $synthetic {Report $s}
        if {$quiet} {
          if {$tapme} {
            foreach l [::tapme::summary] {puts stderr $l}
          } else {
            set passed [expr {[dict size $units] - $failures - [llength $skipped]}]
            puts stderr "[dict size $units] tests: $passed passed, $failures failed, [llength $skipped] skipped"
          }
          flush stderr
        }


      } finally {


        if {$cleanup && $staging ne {false}} {
          if {[catch {file delete -force -- $staging}]} {
            if {$verbose} {puts stderr "failed to remove temporary directory $staging"}
          } else {
            if {$verbose} {puts stderr "removed temporary directory $staging"}
          }
        }


      }


      exit [expr {$failures ? 1 : 0}]


    } on error {return opts} {
      puts stderr $return
      if {$verbose} {puts stderr [dict get $opts -errorinfo]}
      if {!$quiet} {puts "Bail out!"}
      exit 1
    }


  }


  ### Custom code which slurped the testme package's code
  
  
  proc with {var list code} {
    upvar 1 $var v
    if {[catch {set v}]} {set v [list]}
    set list [concat $v $list]
    apply [list $var $code] $list
  }


}