# Testme - a testing pico framework for Tcl
# https://github.com/okhlybov/testme


package require Tcl 8.6


package require Thread


namespace eval ::testme {


  variable version
  regexp -- {-(\d+(?:\.\d+)*)$} [file rootname [file tail [info script]]] ~ version


  # The inter-level protocol record: field names with their defaults.
  # The core fields ::argv0 & ::nesting are computed per level explicitly;
  # every other field is propagated to the nested interpreters as-is, or
  # seeded with its default when absent, ex. under a legacy driver which
  # knows nothing about it. Extending the protocol takes adding a field
  # right here and nothing else
  variable fields {
    ancestors {}
    bailout false
  }


  namespace export unit


  proc Import {source} {
    variable executor
    variable version
    variable seq
    variable fields
    set norm [file normalize $source]
    if {[lsearch -exact $::ancestors $norm] < 0} {lappend ::ancestors $norm}
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
      $box eval {namespace eval ::testme {namespace export unit}}
      $box eval set ::argv0 $norm
      $box eval set ::nesting [incr $::nesting -1]
      foreach {name default} $fields {
        if {[info exists ::$name]} {
          $box eval [list set ::$name [set ::$name]]
        } else {
          $box eval [list set ::$name $default]
        }
      }
      $box eval [list package ifneeded testme $version "[list ::testme::nest [file dirname $norm]]; [list package provide testme $version]"]
      $box eval {
        cd [file dirname $::argv0]
        source [file tail $::argv0]
      }
    } finally {
      interp delete $box
    }
  }


  # Nested suite lookup & processing. Always executed by the driving
  # interpreter of the enclosing level, be it the toplevel machinery or
  # a self-loaded module copy within a legacy nesting level
  proc Nest {dir} {
    set wd [pwd]
    foreach source [glob -nocomplain -directory $dir [file join * [file tail $::argv0]]] {
      set source [file normalize $source]
      if {[lsearch -exact $::ancestors $source] >= 0} {continue}
      try {
        Import $source
      } on error {e o} {
        # The fail fast policy: re-raise when bailing out is requested,
        # otherwise contain the failure and let the run continue
        if {[info exists ::bailout] && $::bailout} {
          return -code error -errorinfo [dict get $o -errorinfo] $e
        }
        if {[llength [info commands ::testme::FailSuite]]} {
          FailSuite $source $e
        } else {
          catch {puts stderr "failed to process suite $source: $e"}
        }
      } finally {cd $wd}
    }
  }


  ### Toplevel code


  try {set ::nesting} on error {} {


    if {![info exists ::argv0] || ![file isfile [file normalize $::argv0]]} {
      error {testme must be required by a test suite script being executed (invalid ::argv0)}
    }


    package require platform


    try {




      package require clip


      variable verbose false


      variable full false


      variable quiet false


      variable staging false


      variable premature false


      variable cleanup true

      
      variable jobs 0


      variable failures 0


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


      # TODO
      if {$jobs == 0} {
        set jobs 4
        switch -glob [platform::identify] {
          linux-* {catch {set jobs [exec nproc --all]}}
          win32-* {catch {set jobs $env(NUMBER_OF_PROCESSORS)}}
        }
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


      set ::nesting -1


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
              foreach arg $args {lappend $chan $arg}
            } else {
              set $chan [concat [lrange [set $chan] 0 end-1] "[lindex [set $chan] end]$args"]
            }
          } else {
            tcl::puts {*}$xargs
          }
        }


        proc skip {{reason {}}} {return -code 1073741823 -level 0 $reason}


        proc process {unit} {
          variable stdout [list]
          variable stderr [list]
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
            interp alias unit puts {} puts
            interp alias unit skip {} skip
            unit eval tcl::tm::path add {*}[tcl::tm::path list]
            catch {unit eval "apply {{unit} {[dict get $unit -code]}} {$unit}"} return opts
            return [dict merge $opts [dict create -return $return -stdout $stdout -stderr $stderr -id [dict get $unit -id]]]
          } finally {
            interp delete unit
          }
        }


      }


      variable executor [tpool::create -maxworkers $jobs -initcmd "$paths; $static;"]


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


      # Emits a TAP line: prints it unless the output is suppressed, in
      # which case the tapme consumer is fed instead
      proc Emit {text} {
        variable quiet
        variable tapme
        if {$quiet} {
          if {$tapme} {::tapme::line $text}
        } else {
          puts $text
        }
      }


      # Registers a failed nested suite as a synthetic failed unit, keeping
      # the TAP plan consistent
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


        Import $::argv0


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


  ### Nested code


  if {$::nesting != 0} {
    # Legacy path: reached only when this module copy is loaded by an
    # older-generation driver which doesn't pre-register itself in this
    # interpreter. Seed the protocol fields it knows nothing about with
    # their roster defaults
    variable fields
    foreach {name default} $fields {
      if {![info exists ::$name]} {set ::$name $default}
    }
    set wd [pwd]
    foreach source [glob -nocomplain [file join * [file tail $::argv0]]] {
      set source [file normalize $source]
      if {[lsearch -exact $::ancestors $source] >= 0} {continue}
      try {Import $source} finally {cd $wd}
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