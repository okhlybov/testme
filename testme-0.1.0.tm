package require Tcl 8.6-


namespace eval ::testme {


# The same source presents a different face at every level of the suite tree:
# the toplevel face (no ::testme::Context yet) is the driver owning the thread pool;
# the nested face (the context pre-seeded by the driver) is the per-suite unit command.
# Recursion is thereby accounted for: the driver reruns the toplevel script itself
# as a nested suite, and every deeper level is just another nested suite.
# The unit layer never loads this source at all: the worker plants the helpers
# (the unit record accessor, skip, with) together with a provide-only package stub.
if {[info exists Context]} { set context {nested} } else { set context {toplevel} }


### Nested context: the per-suite face
if {$context eq {nested}} {

  # Declare a unit of work. The submission is immediate - a parametrization cycle
  # is expected to submit the whole series before any unit starts running -
  # and the returned ticket is the unit number in the TAP plan.
  # The submission crosses the interpreter boundary through the ::testme::submit
  # alias planted by the driver.
  # Declare a unit of work. The submission is immediate - a parametrization cycle
  # is expected to submit the whole series before any unit starts running -
  # and the returned ticket is the unit number in the TAP plan.
  # The submission crosses the interpreter boundary through the ::testme::submit
  # alias planted by the driver.
  # Core unit accepts minimal options: test identity (-name, -tags), directives
  # (-skip, -todo), and standard stream redirection (-stdout, -stderr, -output).
  # Advanced execution options (such as -timeout and sandbox staging) are relegated
  # to specific unit wrappers like shellme::unit.
  proc unit {args} {
    set nargs [llength $args]
    if {$nargs < 1 || $nargs % 2 == 0} {
      error "usage: testme::unit ?-name string? ?-tags list? ?-skip reason? ?-todo reason? ?-stdout file? ?-stderr file? ?-output file? code"
    }
    set opts [lrange $args 0 end-1]
    set code [lindex $args end]
    foreach {k v} $opts {
      if {$k ni {-name -tags -skip -todo -stdout -stderr -output}} {
        error "testme::unit: unrecognized option \"$k\", expected -name, -tags, -skip, -todo, -stdout, -stderr, -output"
      }
    }
    return [::testme::submit $opts $code]
  }

  # Declare a subtest block containing child units
  proc subtest {args} {
    set nargs [llength $args]
    if {$nargs < 1 || $nargs % 2 == 0} {
      error "usage: testme::subtest ?-name string? ?-tags list? ?-skip reason? ?-todo reason? code"
    }
    set opts [lrange $args 0 end-1]
    set code [lindex $args end]
    foreach {k v} $opts {
      if {$k ni {-name -tags -skip -todo}} {
        error "testme::subtest: unrecognized option \"$k\", expected -name, -tags, -skip, -todo"
      }
    }
    return [::testme::subtest_submit $opts $code]
  }

  namespace export unit subtest
  catch {namespace eval :: {namespace import ::testme::unit ::testme::subtest}}

}


### Toplevel context: the driver face
if {$context eq {toplevel}} {

  # A bare require (an interactive shell, a sourced snippet) has no suite script to rerun;
  # refuse it with an explicit diagnostic instead of mistaking the shell itself for a suite
  if {![info exists ::argv0] || $::argv0 eq {} ||
      [file normalize $::argv0] eq [file normalize [info nameofexecutable]] ||
      ![file isfile [file normalize $::argv0]]} {
    puts stderr "testme: must be required by a test suite script file being executed (invalid ::argv0)"
    exit 1
  }

  catch {fconfigure stdout -buffering line}
  catch {fconfigure stderr -buffering line}

  # The module version is carried by the file name
  set version 0
  regexp -- {-(\d+(?:\.\d+)*)$} [file rootname [file tail [info script]]] -> version

  # The TAP dialect: 14 streams the test points in completion order (real-time progress
  # for the units taking wildly differing times); 13 orders them strictly for the sake
  # of the older consumers - the command line and TESTME_OPTS select
  set tap 0

  # The driver policy flags, set by the command line options below
  variable verbose false
  variable full false
  variable cleanup true
  variable premature false
  variable quiet false
  variable staging false
  variable nested false
  variable serial false

  # The driver command line is consumed by the clip parser;
  # -j/--jobs overrides the worker count, --tap selects the TAP dialect
  # (14 streams the test points in completion order for the real-time progress,
  # 13 orders them strictly for the older consumers);
  # the trailing arguments are the tag filters: +tag (or a bare word) selects
  # the units carrying the tag, -tag deselects them; -- ends the options
  # so the filters may look like ones
  variable jobs 0
  variable timeout 0
  variable source_name {}
  variable include [list]
  variable exclude [list]
  if {[catch {
    package require clip
    set opts {
      {{--jobs= -j=} -info "set maximum number of parallel units" -default 0 -slot jobs}
      {{-S= --source=} -info "set suite script name to discover during descent" -default {} -slot source_name}
      {{--tap=} -info "emit the TAP version: 14 (streamed) or 13 (strictly ordered)" -default 14 -slot tap}
      {{--timeout=} -info "set the default unit timeout in seconds (0 = none)" -default 0 -slot timeout}
      {{-n --nested} -info "emit nested TAP 14 subtests" -default true -slot nested}
      {{-s --serial} -info "run units sequentially without thread pool" -default true -slot serial}
      {{-v --verbose} -info "dump unit output to standard error channel" -default true -slot verbose}
      {{-F --full-dump} -info "dump unit output for succeeded tests as well" -default true -slot full}
      {{-K --keep} -info "keep temporary directories & files" -default false -slot cleanup}
      {{-e --bailout} -info "bail out on first failure" -default true -slot premature}
      {{-q --quiet} -info "suppress all output, report through the exit code only" -default true -slot quiet}
      {{-T --staging} -info "manage staging directory in \$TMPDIR" -default true -slot staging}
      {{-h --help} -info "print help" -apply {
        puts stderr "usage: $::argv0 \[options\] \[--\] \[+tag ...\] \[-tag ...\] \[tag ...\]"
        puts stderr {}
        puts stderr {    +tag | tag    execute only units with the specified tag(s)}
        puts stderr {    -tag          skip units with the specified tag(s)}
        clip::usage $::testme::opts {} stderr
        exit 0
      }}
      {{--version} -info "print package version" -apply {
        puts $::testme::version
        exit 0
      }}
    }
    set filters [list]
    if {[info exists ::env(TESTME_OPTS)] && [string trim $::env(TESTME_OPTS)] ne {}} {
      if {[catch { list {*}$::env(TESTME_OPTS) } envArgs]} {
        error "testme: invalid TESTME_OPTS: $envArgs"
      }
      if {[catch { clip::parse $envArgs $opts } envFilters]} {
        error "testme: invalid TESTME_OPTS: $envFilters"
      }
      if {$jobs != 0 && (![string is integer -strict $jobs] || $jobs <= 0)} {
        error "testme: invalid TESTME_OPTS: invalid job count: $jobs"
      }
      if {$serial && $jobs != 0} {
        error "testme: invalid TESTME_OPTS: -s/--serial conflicts with -j/--jobs"
      }
      if {$tap != 0 && $tap != 13 && $tap != 14} {
        error "testme: invalid TESTME_OPTS: unsupported TAP version: $tap"
      }
      if {![string is double -strict $timeout] || $timeout < 0} {
        error "testme: invalid TESTME_OPTS: invalid timeout: $timeout"
      }
      set filters $envFilters
    }
    set envSerial $serial
    set envJobs $jobs
    set serial false
    set jobs 0
    set cliFilters [clip::parse $::argv $opts]
    set cliHasSerial $serial
    set cliHasJobs [expr {$jobs != 0}]
    if {$cliHasSerial && $cliHasJobs} {
      puts stderr "testme: -s/--serial conflicts with -j/--jobs"
      exit 1
    }
    if {!$cliHasSerial && !$cliHasJobs} {
      set serial $envSerial
      set jobs $envJobs
    }
    lappend filters {*}$cliFilters
  } err]} {
    puts stderr $err
    exit 1
  }
  if {$jobs != 0 && (![string is integer -strict $jobs] || $jobs <= 0)} {
    puts stderr "testme: invalid job count: $jobs"
    exit 1
  }
  if {$serial && $jobs != 0} {
    puts stderr "testme: -s/--serial conflicts with -j/--jobs"
    exit 1
  }
  if {!$serial} {
    if {[catch {package require Thread}]} {
      if {$jobs != 0} {
        puts stderr "testme: -j/--jobs requires the Thread package"
        exit 1
      }
      set serial true
    }
  }
  if {$tap == 0} { set tap 14 }
  if {$tap != 13 && $tap != 14} {
    puts stderr "testme: unsupported TAP version: $tap"
    exit 1
  }
  if {![string is double -strict $timeout] || $timeout < 0} {
    puts stderr "testme: invalid timeout: $timeout"
    exit 1
  }
  if {$tap != 14} { set nested false }
  foreach arg $filters {
    switch -glob -- $arg {
      +* { lappend include [string trimleft $arg +] }
      -* { lappend exclude [string trimleft $arg -] }
      default { lappend include $arg }
    }
  }

  # The origin directory: the logs and the default staging anchor
  # before any suite changes the current directory
  variable origin [pwd]

  # The worker count is sized after the machine; the -j option (via command line or
  # TESTME_OPTS) takes precedence, otherwise platform detection determines the core count
  proc CoreCount {} {
    # Linux: the kernel cpu list, then the cpuinfo tally
    if {![catch {set f [open /sys/devices/system/cpu/online r]}]} {
      set n 0
      try {
        set n [CountCPUs [read $f]]
      } finally {
        close $f
      }
      if {$n > 0} { return [CgroupCap $n] }
    }
    if {![catch {
      set f [open /proc/cpuinfo r]
      try { set data [read $f] } finally { close $f }
    }] && [set n [llength [regexp -all -line -inline {^processor\s*:} $data]]] > 0} {
      return [CgroupCap $n]
    }
    # Windows: the canonical environment variable
    if {[info exists ::env(NUMBER_OF_PROCESSORS)] && [string is integer -strict $::env(NUMBER_OF_PROCESSORS)] && $::env(NUMBER_OF_PROCESSORS) > 0} {
      return $::env(NUMBER_OF_PROCESSORS)
    }
    # macOS & the BSDs
    foreach cmd {{sysctl -n hw.logicalcpu} {sysctl -n hw.ncpu}} {
      if {![catch {exec {*}$cmd} n] && [string is integer -strict $n] && $n > 0} { return $n }
    }
    # Linux without sysfs, Solaris & AIX
    foreach cmd {{nproc} {getconf _NPROCESSORS_ONLN}} {
      if {![catch {exec {*}$cmd} n] && [string is integer -strict $n] && $n > 0} { return [CgroupCap $n] }
    }
    return 4
  }

  # Counts the cpus in a kernel cpu list ("0-3,8" style ranges or single numbers)
  proc CountCPUs {data} {
    set count 0
    foreach range [split [string trim $data] ,] {
      if {$range eq {}} {continue}
      if {[regexp {^(\d+)-(\d+)$} $range -> start end]} {
        incr count [expr {$end - $start + 1}]
      } elseif {[string is integer -strict $range]} {
        incr count
      }
    }
    return $count
  }

  # The effective CPU limit of the current cgroup (the quota rounded up or the cpuset size,
  # whichever is tighter), or an empty string when the process is unconstrained.
  # Handles cgroup v2 and v1, resolving the process cgroup path through /proc/self/cgroup
  proc CgroupLimit {} {
    set dirs [list /sys/fs/cgroup]
    if {![catch {set f [open /proc/self/cgroup r]}]} {
      try {
        set data [read $f]
      } finally {
        close $f
      }
      foreach line [split $data \n] {
        # v2: "0::/path"; v1: "12:cpu,cpuacct:/path"
        if {![regexp {^\d+:[^:]*:(.+)$} $line -> path]} {continue}
        if {$path eq {/}} {
          lappend dirs /sys/fs/cgroup
        } else {
          lappend dirs [file join /sys/fs/cgroup $path]
          lappend dirs [file join /sys/fs/cgroup cpu,cpuacct $path]
        }
      }
    }
    set limits [list]
    foreach dir $dirs {
      # v2 quota: "QUOTA PERIOD" or "max PERIOD"
      set f [file join $dir cpu.max]
      if {[file readable $f] && ![catch {
        set f [open $f r]
        try {
          lassign [split [string trim [read $f]] quota period]
        } finally {
          close $f
        }
      }] && [string is integer -strict $quota] && [string is integer -strict $period] && $quota > 0 && $period > 0} {
        lappend limits [expr {int(ceil(double($quota) / $period))}]
      }
      # v1 quota: -1 means unlimited
      set q [file join $dir cpu.cfs_quota_us]
      set p [file join $dir cpu.cfs_period_us]
      if {[file readable $q] && [file readable $p] && ![catch {
        set f [open $q r]
        try { set quota [string trim [read $f]] } finally { close $f }
        set f [open $p r]
        try { set period [string trim [read $f]] } finally { close $f }
      }] && [string is integer -strict $quota] && $quota > 0 && [string is integer -strict $period] && $period > 0} {
        lappend limits [expr {int(ceil(double($quota) / $period))}]
      }
      # cpusets
      foreach name {{cpuset.cpus.effective} {cpuset/cpuset.effective_cpus}} {
        set f [file join $dir {*}$name]
        if {[file readable $f] && ![catch {
          set f [open $f r]
          try { set data [string trim [read $f]] } finally { close $f }
          set count [CountCPUs $data]
        }] && $count > 0} {
          lappend limits $count
        }
      }
    }
    if {[llength $limits]} {return [::tcl::mathfunc::min {*}$limits]}
    return {}
  }

  # Caps a detected processor count by the cgroup limit
  proc CgroupCap {count} {
    set limit [CgroupLimit]
    if {$limit ne {} && $limit > 0 && $limit < $count} {return $limit}
    return $count
  }

  # Creates a temporary directory trying the caller roots, then TMPDIR, TMP and /tmp
  proc MakeTempDir {args} {
    set roots $args
    foreach var {TMPDIR TMP} {
      if {[info exists ::env($var)]} { lappend roots $::env($var) }
    }
    lappend roots /tmp
    set dir ""
    foreach r $roots {
      for {set attempt 0} {$attempt < 16} {incr attempt} {
        set tag "[pid].[clock microseconds].[expr {int(rand()*999999)}]"
        set dir [file join $r testme.$tag]
        if {![file exists $dir] && ![catch {file mkdir $dir}]} { return $dir }
      }
    }
    error "failed to create temporary directory $dir"
  }

  # The managed staging directory: created when requested, exported as TMPDIR
  # for the units to place their garbage into, removed on completion
  variable stage false
  if {$staging} {
    set stage [set ::env(TMPDIR) [MakeTempDir]]
    if {$verbose} {puts stderr "created temporary directory $stage"}
  }

  # Idle workers must exist up front: pools relying on lazy worker spawning
  # were observed to dispatch queued jobs one at a time, defeating parallelism.
  # The pool itself is created once the worker script is defined below: the
  # -initcmd ships it into every worker thread once, so the jobs stay small
  variable cores 1
  variable pool {}
  variable pending [dict create]
  variable serialQueue [list]
  variable boxes [list]
  variable nboxes 0
  variable index 0
  variable passed 0
  variable failed 0
  variable ran [dict create]
  variable units [dict create]
  variable inbox [dict create]
  variable next 1
  variable streaming 0
  variable where [dict create]
  variable doomed 0
  variable nscopes 0
  variable scopes [dict create 0 [dict create \
    id 0 \
    parent -1 \
    depth 0 \
    name {} \
    items [list] \
    pending 0 \
    skip {} \
    todo {} \
  ]]
  variable boxScope [dict create]
  variable boxScopeStack [dict create]
  variable unitScope [dict create]
  variable unitOutcome [dict create]
  variable scopeFailed [dict create]
  variable nextTop 1
  # Auto-named subtests draw from their own counter: sharing the unit counter
  # would punch holes into the flat roster (a number announced, never run)
  variable nsubtests 0
  # One environment snapshot taken after discovery serves every unit
  variable envSnapshot {}

  # Seed the context for rerunning this very script as a nested suite
  set script [expr {$source_name ne {} ? $source_name : [file tail $::argv0]}]
  set Context [dict create \
    -root [file dirname [file normalize $::argv0]] \
    -script $script \
     tcl::tm::path [tcl::tm::path list] \
  ]

  # The process output streams belong to the runner's TAP report: unit or
  # suite code (or a program it launches) writing onto them is refused
  # outright rather than contained - external programs belong to shellme.
  # A copy of this guard is installed into every interpreter running suite
  # or unit code (and spliced into the worker below); it scans the exec
  # arguments for stream redirections and lets everything else through verbatim
  variable StreamGuard {
    if {[llength [info commands ::testme::RealExec]] == 0} {
      rename exec ::testme::RealExec
    }
    proc exec {args} {
      set argv $args
      set background [expr {[lindex $argv end] eq "&"}]
      if {$background} {set argv [lrange $argv 0 end-1]}
      set n [llength $argv]
      for {set i 0} {$i < $n} {incr i} {
        set w [lindex $argv $i]
        set chan {}
        if {[regexp {^(?:2>@|>&@|>@)(stdout|stderr)$} $w -> chan]} {
        } elseif {($w eq {>@} || $w eq {2>@} || $w eq {>&@})
                  && [lindex $argv [expr {$i + 1}]] in {stdout stderr}} {
          set chan [lindex $argv [expr {$i + 1}]]
        }
        if {$chan ne {}} {
          return -code error "the code must not write to the process streams (redirection to $chan); run external programs through shellme"
        }
      }
      if {$background} {lappend argv &}
      tailcall ::testme::RealExec {*}$argv
    }
  }

  # The worker-side unit runner. The pool -initcmd installs it once per worker
  # thread (the serial mode evaluates the same script in the driver interpreter),
  # so the jobs carry only the unit record instead of the runner script.
  # Procedures live in ::testme::worker, avoiding global namespace pollution.
  # The unit code runs in a clean interpreter destroyed right after; its writes
  # to the standard channels are tallied by the puts override (and optionally
  # mirrored to files via -stdout, -stderr, -output).
  variable workerInit {
    namespace eval ::testme::worker {
      variable stdout [list]
      variable stderr [list]
      variable partial
      array set partial {stdout 0 stderr 0}
      variable skipped 0
      variable skip_reason {}
      variable record {}
      variable childpids [list]
      variable atend [list]
      variable redirs [dict create]

      variable StreamGuard {
        if {[llength [info commands ::testme::RealExec]] == 0} {
          rename exec ::testme::RealExec
        }
        proc exec {args} {
          set argv $args
          set background [expr {[lindex $argv end] eq "&"}]
          if {$background} {set argv [lrange $argv 0 end-1]}
          set n [llength $argv]
          for {set i 0} {$i < $n} {incr i} {
            set w [lindex $argv $i]
            set chan {}
            if {[regexp {^(?:2>@|>&@|>@)(stdout|stderr)$} $w -> chan]} {
            } elseif {($w eq {>@} || $w eq {2>@} || $w eq {>&@})
                      && [lindex $argv [expr {$i + 1}]] in {stdout stderr}} {
              set chan [lindex $argv [expr {$i + 1}]]
            }
            if {$chan ne {}} {
              return -code error "the code must not write to the process streams (redirection to $chan); run external programs through shellme"
            }
          }
          if {$background} {lappend argv &}
          tailcall ::testme::RealExec {*}$argv
        }
      }

      proc ResetState {unit} {
        variable stdout [list]
        variable stderr [list]
        variable partial
        array set partial {stdout 0 stderr 0}
        variable skipped 0
        variable skip_reason {}
        variable record $unit
        variable childpids [list]
        variable atend [list]
        variable redirs [dict create]

        # Configure file redirections (-stdout, -stderr, -output)
        set outPath {}
        set errPath {}
        if {[dict exists $unit -output]} {
          set outPath [dict get $unit -output]
          set errPath $outPath
        }
        if {[dict exists $unit -stdout]} { set outPath [dict get $unit -stdout] }
        if {[dict exists $unit -stderr]} { set errPath [dict get $unit -stderr] }

        if {$outPath ne {} && $outPath eq $errPath} {
          if {![catch {
            file mkdir [file dirname [file normalize $outPath]]
            set f [open $outPath a]
            fconfigure $f -buffering line -translation auto
            dict set redirs stdout $f
            dict set redirs stderr $f
          }]} {}
        } else {
          if {$outPath ne {}} {
            if {![catch {
              file mkdir [file dirname [file normalize $outPath]]
              set f [open $outPath a]
              fconfigure $f -buffering line -translation auto
              dict set redirs stdout $f
            }]} {}
          }
          if {$errPath ne {}} {
            if {![catch {
              file mkdir [file dirname [file normalize $errPath]]
              set f [open $errPath a]
              fconfigure $f -buffering line -translation auto
              dict set redirs stderr $f
            }]} {}
          }
        }
      }

      proc CloseRedirs {} {
        variable redirs
        foreach f [lsort -unique [dict values $redirs]] {
          catch {close $f}
        }
        set redirs [dict create]
      }

      proc Puts {args} {
        variable stdout
        variable stderr
        variable partial
        variable redirs
        set xargs $args
        set newline 1
        if {[llength $args] > 1 && [lindex $args 0] eq {-nonewline}} {
          set args [lrange $args 1 end]
          set newline 0
        }
        if {[llength $args] == 1} {
          set chan stdout
          set text [lindex $args 0]
        } elseif {[llength $args] == 2} {
          lassign $args chan text
        } else {
          tailcall ::tcl::puts {*}$xargs
        }
        if {$chan eq {stdout} || $chan eq {stderr}} {
          set lines [split $text \n]
          set first [lindex $lines 0]
          set rest [lrange $lines 1 end]
          if {$partial($chan) && [llength [set $chan]] > 0} {
            lset $chan end "[lindex [set $chan] end]$first"
          } else {
            lappend $chan $first
          }
          foreach line $rest { lappend $chan $line }
          set partial($chan) [expr {!$newline}]

          if {[dict exists $redirs $chan]} {
            set f [dict get $redirs $chan]
            catch {
              if {$newline} {
                puts $f $text
              } else {
                puts -nonewline $f $text
              }
            }
          }
        } else {
          ::tcl::puts {*}$xargs
        }
      }

      proc Skip {{reason {}}} {
        variable skipped 1
        variable skip_reason $reason
        return -code 1073741823 -level 0 $reason
      }

      proc Context {args} {
        variable record
        if {![llength $args]} {return $record}
        tailcall dict get $record {*}$args
      }

      proc RegisterPids {pids} {
        variable childpids
        foreach pid $pids { lappend childpids $pid }
      }

      proc UnregisterPids {pids} {
        variable childpids
        set childpids [lsearch -all -inline -not -exact $childpids {*}$pids]
      }

      proc ReapChildren {} {
        variable childpids
        foreach pid $childpids {
          if {$::tcl_platform(platform) eq "windows"} {
            catch {exec taskkill /PID $pid /T /F}
          } elseif {[catch {exec kill -9 -- -$pid}]} {
            catch {exec kill -9 -- $pid}
          }
        }
        set childpids [list]
      }

      proc AtEndRegister {script} {
        variable atend
        lappend atend $script
      }

      proc RunAtEnd {} {
        variable atend
        foreach script $atend {
          catch {uplevel #0 $script}
        }
        set atend [list]
      }

      proc SetupInterp {u unit paths version envSnapshot limit} {
        variable StreamGuard

        # Isolate ::env so the unit operates on a private copy without mutating the process-wide environment
        $u eval [list apply {{snapshot} {
          trace add variable ::env unset {apply {{args} {return -code error "blocked"}}}
          catch {unset -nocomplain ::env}
          array set ::env $snapshot
        }} $envSnapshot]

        # The module lookup paths so the unit code may load shellme and the extra/ companions
        interp eval $u [list tcl::tm::path add {*}$paths]
        foreach p $paths {
          set extraDir [file join $p extra]
          if {[file isdirectory $extraDir]} {
            foreach tm [glob -nocomplain -directory $extraDir *.tm] {
              if {[regexp {^([^-]+)-(\d+(?:\.\d+)*)\.tm$} [file tail $tm] -> pkg ver]} {
                interp eval $u [list package ifneeded $pkg $ver [list apply {{f p v} {source $f; package provide $p $v}} $tm $pkg $ver]]
              }
            }
          }
        }

        # The unit layer face of the testme package: the helpers only
        interp eval $u [list package ifneeded testme $version [list package provide testme $version]]
        interp eval $u {namespace eval ::testme {}}
        interp alias $u ::testme::unit {} ::testme::worker::Context
        interp eval $u {namespace eval ::testme {namespace export unit}}
        catch {interp eval $u {namespace eval :: {namespace import ::testme::unit}}}
        interp eval $u [list proc ::testme::with {var list code} {
          upvar 1 $var v
          if {[catch {set v}]} {set v [list]}
          set list [concat $v $list]
          apply [list $var $code] $list
        }]
        interp eval $u {namespace eval ::testme {namespace export with}}
        interp alias $u ::skip {} ::testme::worker::Skip

        # The child processes started by the unit (shellme etc.) register here,
        # so the worker can reap them once the unit is over, whatever happened
        interp alias $u ::testme::RegisterPids {} ::testme::worker::RegisterPids
        interp alias $u ::testme::UnregisterPids {} ::testme::worker::UnregisterPids

        # The timeout-safe cleanup hook (sandbox removal and friends)
        interp alias $u ::testme::AtEnd {} ::testme::worker::AtEndRegister

        # Unit code execution guards
        interp eval $u {proc exit {args} {return -code error "the unit code requested to terminate the process: exit $args"}}
        interp eval $u {proc cd {args} {return -code error "the unit code must not change working directory: use shellme instead"}}

        # fcopy onto process streams is denied
        interp eval $u {
          if {[llength [info commands ::testme::RealFcopy]] == 0} {
            rename fcopy ::testme::RealFcopy
          }
          proc fcopy {input output args} {
            if {$output eq {stdout} || $output eq {stderr}} {
              return -code error "the code must not write to the process streams (fcopy to $output); write to a file instead"
            }
            tailcall ::testme::RealFcopy $input $output {*}$args
          }
        }

        # The stream redirection guard for programs the unit launches
        interp eval $u $StreamGuard

        # The basic output capture: stdout and stderr are tallied
        interp alias $u ::CapturePuts {} ::testme::worker::Puts
        interp eval $u {
          rename puts ::tcl::puts
          proc puts {args} {
            set xargs $args
            if {[llength $args] > 1 && [lindex $args 0] eq {-nonewline}} {
              set rest [lrange $args 1 end]
            } else {
              set rest $args
            }
            set chan [expr {[llength $rest] == 1 ? "stdout" : [lindex $rest 0]}]
            if {$chan eq {stdout} || $chan eq {stderr}} {
              CapturePuts {*}$xargs
            } else {
              ::tcl::puts {*}$xargs
            }
          }
          namespace eval ::tcl::chan {}
          catch {rename ::tcl::chan::puts ::tcl::chan::realPuts}
          proc ::tcl::chan::puts {args} {
            set rest $args
            if {[lindex $rest 0] eq {-nonewline}} {set rest [lrange $rest 1 end]}
            if {[llength $rest] <= 1 || [lindex $rest 0] in {stdout stderr}} {
              tailcall ::puts {*}$args
            }
            tailcall ::tcl::chan::realPuts {*}$args
          }
        }

        # The unit body runs as a named procedure
        interp eval $u [list proc ::testme::UnitBody {} [dict get $unit -code]]

        # The optional unit time limit
        if {$limit > 0} {
          set deadline [expr {[clock milliseconds] + int($limit * 1000)}]
          interp limit $u time -seconds [expr {$deadline / 1000}] \
            -milliseconds [expr {$deadline % 1000}] -granularity 1
        }
      }

      proc RunUnit {unit paths version {envSnapshot {}} {defTimeout 0}} {
        variable stdout
        variable stderr
        variable skipped
        variable skip_reason

        # One environment snapshot taken after discovery serves every unit
        if {$envSnapshot eq {}} {
          if {[llength [info commands tsv::get]]} {
            catch {set envSnapshot [tsv::get ::testme env]}
          }
          if {$envSnapshot eq {}} {set envSnapshot [array get ::env]}
        }

        ResetState $unit

        set limit 0
        if {[dict exists $unit -timeout]} {set limit [dict get $unit -timeout]}
        if {$limit <= 0 && $defTimeout > 0} {set limit $defTimeout}

        set u [interp create]
        try {
          SetupInterp $u $unit $paths $version $envSnapshot $limit
          set code [catch {interp eval $u ::testme::UnitBody} result options]
        } finally {
          catch {interp delete $u}
          catch {ReapChildren}
          catch {RunAtEnd}
          CloseRedirs
        }

        if {$code == 1073741823 || $skipped} {
          set status skipped
          if {$code != 1073741823} { set result $skip_reason }
        } elseif {$code == 0} {
          set status ok
        } elseif {$code == 1 && [dict exists $options -errorcode]
                  && [lrange [dict get $options -errorcode] 0 2] eq {TCL LIMIT TIME}} {
          set status timeout
          set result "timed out after $limit s"
        } else {
          set status error
        }

        set out $stdout
        set err $stderr
        return [list $status $result $options $out $err]
      }
    }

    proc ::RunUnit {args} { tailcall ::testme::worker::RunUnit {*}$args }
  }

  # Ship the runner into its hosting interpreters: the worker threads receive
  # it through the pool -initcmd once per thread, the serial mode evaluates the
  # same script under the driver interpreter
  if {!$serial} {
    set cores [expr {$jobs > 0 ? $jobs : [CoreCount]}]
    set pool [tpool::create -minworkers $cores -maxworkers $cores \
      -initcmd $workerInit]
    # Enter submit phase: the units accumulate while the suite tree is being discovered
    tpool::suspend $pool
  } else {
    eval $workerInit
  }
  # The shared elements of two lists
  proc Intersect {a b} {
    set r {}
    foreach x $a {
      if {[lsearch -exact $b $x] >= 0 && [lsearch -exact $r $x] < 0} { lappend r $x }
    }
    return $r
  }

  # A display name for synthetic units: the path relative to the suite root when possible
  proc Relative {path} {
    variable Context
    set prefix [file normalize [dict get $Context -root]]/
    if {[string first $prefix $path] == 0} {
      return [string range $path [string length $prefix] end]
    }
    return $path
  }

  # Allocates a new scope under a parent scope
  proc CreateScope {name parent {opts {}}} {
    variable nscopes
    variable scopes
    set id [incr nscopes]
    set parentDepth [dict get $scopes $parent depth]
    set depth [expr {$parentDepth + 1}]
    set skip {}; set todo {}
    if {[dict exists $opts -skip]} { set skip [dict get $opts -skip] }
    if {[dict exists $opts -todo]} { set todo [dict get $opts -todo] }
    dict set scopes $id [dict create \
      id $id \
      parent $parent \
      depth $depth \
      name $name \
      items [list] \
      pending 0 \
      skip $skip \
      todo $todo \
    ]
    dict update scopes $parent parentDict {
      dict lappend parentDict items [list scope $id]
    }
    return $id
  }

  # Receive a subtest block submission from a suite
  proc SubtestSubmit {box opts code} {
    variable nested
    variable boxScope
    variable boxScopeStack
    variable scopes
    variable nsubtests
    set name {}
    if {[dict exists $opts -name]} { set name [dict get $opts -name] }
    if {$name eq {}} {
      incr nsubtests
      set name "subtest$nsubtests"
    }
    set currentScope 0
    if {[dict exists $boxScope $box]} {
      set currentScope [dict get $boxScope $box]
    }
    if {![dict exists $opts -skip] && [dict exists $scopes $currentScope skip] && [dict get $scopes $currentScope skip] ne {}} {
      dict set opts -skip [dict get $scopes $currentScope skip]
    }
    if {![dict exists $opts -todo] && [dict exists $scopes $currentScope todo] && [dict get $scopes $currentScope todo] ne {}} {
      dict set opts -todo [dict get $scopes $currentScope todo]
    }
    if {!$nested} {
      $box eval $code
      return
    }
    set subScope [CreateScope $name $currentScope $opts]
    dict set boxScope $box $subScope
    dict lappend boxScopeStack $box $subScope
    try {
      $box eval $code
    } finally {
      set stack [dict get $boxScopeStack $box]
      set stack [lrange $stack 0 end-1]
      dict set boxScopeStack $box $stack
      dict set boxScope $box [lindex $stack end]
    }
    return $subScope
  }

  # Receive a unit submission from a suite (through the ::testme::submit alias);
  # the ticket returned to the submitting suite is the unit number in the TAP plan
  proc Submit {box opts code} {
    variable pool
    variable pending
    variable index
    variable units
    variable include
    variable exclude
    variable where
    variable version
    variable cleanup
    variable stage
    variable nested
    variable serial
    variable serialQueue
    variable boxScope
    variable scopes
    variable unitScope
    variable timeout
    set name {}; set skip {}; set todo {}
    if {[dict exists $opts -name]} { set name [dict get $opts -name] }
    if {[dict exists $opts -skip]} { set skip [dict get $opts -skip] }
    if {[dict exists $opts -todo]} { set todo [dict get $opts -todo] }
    set currentScope 0
    if {[dict exists $boxScope $box]} {
      set currentScope [dict get $boxScope $box]
    }
    if {$skip eq {} && [dict exists $scopes $currentScope skip] && [dict get $scopes $currentScope skip] ne {}} {
      set skip [dict get $scopes $currentScope skip]
    }
    if {$todo eq {} && [dict exists $scopes $currentScope todo] && [dict get $scopes $currentScope todo] ne {}} {
      set todo [dict get $scopes $currentScope todo]
    }
    set tags [list]
    catch {set tags [dict get $opts -tags]}
    # Squeeze out empty {} tags
    set tags [lsearch -inline -all -not -exact $tags {}]
    incr index
    if {$name eq {}} { set name "unit$index" }
    if {$skip eq {} && !(([llength $include] == 0 || [llength [Intersect $include $tags]] > 0)
                         && [llength [Intersect $exclude $tags]] == 0)} {
      # The tag filters deselected this unit; it stays in the roster as skipped
      set skip {deselected by tags}
    }
    dict set units $index [list $name $skip $todo]
    if {$nested} {
      dict set unitScope $index $currentScope
      dict update scopes $currentScope s {
        dict lappend s items [list unit $index]
        dict incr s pending
      }
      set p [dict get $scopes $currentScope parent]
      while {$p >= 0} {
        dict update scopes $p ps { dict incr ps pending }
        set p [dict get $scopes $p parent]
      }
    }
    if {$skip ne {}} {
      # A skipped unit is planned but never run
      Deliver $index ok {} {} {} {}
      return $index
    }
    # The unit timeout, when given, must be a positive number; an invalid one
    # fails the unit at once so the mistake surfaces immediately
    if {[dict exists $opts -timeout]
        && (![string is double -strict [dict get $opts -timeout]] || [dict get $opts -timeout] <= 0)} {
      Deliver $index error "invalid -timeout: [dict get $opts -timeout]" {} {} {}
      return $index
    }
    # The unit record: the user options pass through verbatim,
    # the framework fields complete the picture for the unit code
    set sourceDir [dict get $where $box]
    set originDir [file dirname [file normalize $sourceDir]]
    set stageDir [expr {$stage ne {false} ? $stage : $originDir}]
    set record [dict merge $opts [dict create \
      -name $name -tags $tags -code $code -id $index \
      -source $sourceDir \
      -origin $originDir \
      -stage $stageDir \
      -cleanup $cleanup \
    ]]
    set suitePaths {}
    catch {set suitePaths [$box eval {tcl::tm::path list}]}
    if {![llength $suitePaths]} { set suitePaths [tcl::tm::path list] }
    if {$serial} {
      lappend serialQueue [list $index $record $suitePaths $version]
    } else {
      # The empty snapshot argument makes the worker read the shared one
      # taken after discovery; the default timeout rides along per job
      set job [tpool::post -nowait $pool [list ::RunUnit $record $suitePaths $version {} $timeout]]
      dict set pending $job $index
    }
    return $index
  }

  # Canonical file identity: normalized paths do not resolve symlinks,
  # so the (device, inode) pair is what truly says "this very file"
  proc Identity {path} {
    if {[catch {file stat $path st}]} { return [list path $path] }
    list file $st(dev) $st(ino)
  }

  # Terminal transition of a suite: learn the scripts it composed by sourcing
  # (the umbrella trail), then descend into its subdirectories
  proc Retire {box root} {
    variable ran
    # Every script the suite brought in by sourcing must never be run again,
    # be it by another suite, by the descent discovery or by a symlink alias
    set composed {}
    catch {set composed [$box eval {set ::testme::sourced}]}
    foreach path $composed { dict set ran [Identity $path] 1 }
    set suitePaths {}
    catch {set suitePaths [$box eval {tcl::tm::path list}]}
    Descend $root $suitePaths $box
  }

  # Create an isolated suite interpreter over $root and run the script there;
  # the unit submissions arrive synchronously through the alias.
  # The current directory of the suite is its own directory (the boxes and the driver
  # share the thread's one), so the units inherit a meaningful origin directory
  proc Box {root {scriptName {}} {tmpaths {}} {initialScope 0}} {
    variable Context
    variable boxes
    variable nboxes
    variable ran
    variable index
    variable units
    variable where
    variable premature
    variable failed
    variable quiet
    variable verbose
    variable nested
    variable boxScope
    variable boxScopeStack
    variable unitScope
    variable scopes
    if {$scriptName eq {}} {
      set scriptName [dict get $Context -script]
    }
    if {![llength $tmpaths]} {
      set tmpaths [dict get $Context tcl::tm::path]
    }
    # The double execution guard: a script that has already run in this process
    # (composed by an umbrella, aliased by a symlink, discovered twice) is never rerun
    set identity [Identity [file normalize [file join $root $scriptName]]]
    if {[dict exists $ran $identity]} { return }
    dict set ran $identity 1
    set box [interp create suite[incr nboxes]]
    lappend boxes $box
    set script [file join $root $scriptName]
    dict set where $box [file normalize $script]
    dict set boxScope $box $initialScope
    dict set boxScopeStack $box [list $initialScope]
    set wd [pwd]
    try {
      if {[catch {
        # Seed the augmented context so the module takes its nested face when required
        $box eval {namespace eval ::testme {}}
        $box eval [list set ::testme::Context [dict merge $Context [dict create -root $root tcl::tm::path $tmpaths]]]
        # Propagate the module lookup paths so `package require testme` resolves the same copy
        $box eval [list apply {{paths} {
          set current [tcl::tm::path list]
          foreach x [lreverse $paths] {
            # Squash duplicates in the module lookup path
            if {[lsearch $current $x] < 0} { tcl::tm::path add $x }
            set extraDir [file join $x extra]
            if {[file isdirectory $extraDir]} {
              foreach tm [glob -nocomplain -directory $extraDir *.tm] {
                if {[regexp {^([^-]+)-(\d+(?:\.\d+)*)\.tm$} [file tail $tm] -> pkg ver]} {
                  package ifneeded $pkg $ver [list apply {{f p v} {source $f; package provide $p $v}} $tm $pkg $ver]
                }
              }
            }
          }
        }} $tmpaths]
        # The unit submissions cross the interpreter boundary through this alias
        interp alias $box ::testme::submit {} ::testme::Submit $box
        interp alias $box ::testme::subtest_submit {} ::testme::SubtestSubmit $box
        $box eval {namespace eval ::testme {namespace export unit subtest}}
        $box eval {catch {namespace import ::testme::unit ::testme::subtest}}
        # Suite code must not terminate the process either
        $box eval {proc exit {args} {return -code error "the suite code requested to terminate the process: exit $args"}}
        # The suite stdout is the TAP channel of this very run: writing to it
        # during collection is refused; stderr stays free for the suite's
        # own diagnostics
        $box eval {
          rename puts ::testme::RealPuts
          proc puts {args} {
            set rest $args
            if {[lindex $rest 0] eq {-nonewline}} {set rest [lrange $rest 1 end]}
            if {[llength $rest] <= 1 || [lindex $rest 0] eq {stdout}} {
              return -code error "the suite code must not write to stdout during collection; use stderr"
            }
            tailcall ::testme::RealPuts {*}$args
          }
          namespace eval ::tcl::chan {}
          catch {rename ::tcl::chan::puts ::tcl::chan::realPuts}
          proc ::tcl::chan::puts {args} {
            set rest $args
            if {[lindex $rest 0] eq {-nonewline}} {set rest [lrange $rest 1 end]}
            if {[llength $rest] <= 1 || [lindex $rest 0] eq {stdout}} {
              return -code error "the suite code must not write to stdout during collection; use stderr"
            }
            tailcall ::tcl::chan::realPuts {*}$args
          }
        }
        # The stream redirection guard for the programs the suite launches
        $box eval $::testme::StreamGuard
        # The accumulator shared by the suite layer
        $box eval [list proc ::testme::with {var list code} {
          upvar 1 $var v
          if {[catch {set v}]} {set v [list]}
          set list [concat $v $list]
          apply [list $var $code] $list
        }]
        $box eval {namespace eval ::testme {namespace export with}}
        # Trace whatever the suite composes by sourcing (the umbrella trail):
        # the trail is harvested at completion to feed the double execution guard
        $box eval {
          rename source ::testme::source
          proc source {args} {
            if {[llength $args]} {
              set target {}
              catch {set target [file normalize [lindex $args end]]}
              if {$target ne {}} { lappend ::testme::sourced $target }
            }
            uplevel 1 [linsert $args 0 ::testme::source]
          }
        }
        # Run the suite script from its own directory; the submissions post
        # to the suspended pool right away. The absolute path keeps [info script]
        # absolute inside the suite, so the suites derive stable paths
        $box eval [list cd $root]
        $box eval [list source $script]
      } err opts]} {
        incr failed
        if {!$quiet || $verbose} { puts stderr "testme: suite script $script failed: $err" }
        if {$premature} {
          # The bailout policy re-raises: the discovery aborts
          return -options $opts $err
        }
        # A failed suite script becomes a synthetic failed unit so the roster stays honest
        incr index
        dict set units $index [list [Relative [file normalize $script]] {} {}]
        if {$nested} {
          dict set unitScope $index $initialScope
          dict update scopes $initialScope s {
            dict lappend s items [list unit $index]
            dict incr s pending
          }
          set p [dict get $scopes $initialScope parent]
          while {$p >= 0} {
            dict update scopes $p ps { dict incr ps pending }
            set p [dict get $scopes $p parent]
          }
        }
        Deliver $index error "suite script failed: $err" {} {} {}
      }
      Retire $box $root
    } finally {
      cd $wd
    }
  }

  # Look for the scripts sharing the name with the current one
  # in the immediate subdirectories of $root; called once a suite script has finished,
  # so the scripts it composed by sourcing are known before discovery reaches them;
  # deeper levels are reached through the completion of the immediate ones
  proc Descend {root {tmpaths {}} {parentBox {}}} {
    variable Context
    variable nested
    variable boxScope
    set parentScope 0
    if {$nested && $parentBox ne {} && [dict exists $boxScope $parentBox]} {
      set parentScope [dict get $boxScope $parentBox]
    }
    foreach source [glob -nocomplain -directory $root [file join * [dict get $Context -script]]] {
      set subDir [file dirname [file normalize $source]]
      set childScope 0
      if {$nested} {
        set scopeName [file tail $subDir]
        set childScope [CreateScope $scopeName $parentScope]
      }
      Box $subDir [dict get $Context -script] $tmpaths $childScope
    }
  }

  # Says a TAP line unless the run is quiet; the quiet run reports
  # through the exit code only
  proc Say {text} {
    variable quiet
    if {!$quiet} {
      puts $text
      catch {flush stdout}
    }
  }

  # Sanitize single-line TAP fields so embedded newlines cannot corrupt the stream
  proc CleanTapLine {text} {
    string map [list \r\n " " \n " " \r " "] $text
  }

  # Escapes a test point description: an unescaped backslash or hash would
  # leak into the TAP syntax (a hash starts a directive, so a failing unit
  # named "x # TODO y" would read as an expected failure to every consumer)
  proc TapDescription {text} {
    string map [list \\ \\\\ # \\# \r\n " " \n " " \r " "] $text
  }

  # Trims a failure trace at the unit body boundary: the frames below belong
  # to the runner machinery, not the unit; -F/--full-dump keeps them for
  # debugging the framework itself
  proc TrimTrace {trace name} {
    variable full
    if {$full} {return $trace}
    set out {}
    foreach line [split $trace \n] {
      if {[regexp {^\s*\(procedure "::testme::UnitBody" line (\d+)\)} $line -> n]} {
        lappend out "    (unit \"[CleanTapLine $name]\" line $n)"
        return [join $out \n]
      }
      lappend out $line
    }
    return [join $out \n]
  }

  # Print a single TAP test line with its directives and, for a failure, a YAML diagnostic;
  # dump the captured unit channels under -v/-F and log them into per-unit files under -K
  proc Emit {id status result options stdout stderr} {
    variable units
    variable passed
    variable failed
    variable verbose
    variable full
    variable cleanup
    variable stage
    variable origin
    lassign [dict get $units $id] name skip todo
    set name [TapDescription $name]
    set skip [CleanTapLine $skip]
    set todo [CleanTapLine $todo]
    if {$skip ne {}} {
      incr passed
      Say "ok $id - $name # SKIP $skip"
      return
    }
    set directive {}
    if {$todo ne {}} { set directive " # TODO $todo" }
    if {$status eq {ok}} {
      incr passed
      Say "ok $id - $name$directive"
    } elseif {$status eq {skipped}} {
      # The unit skipped itself at run time
      incr passed
      Say "ok $id - $name # SKIP [CleanTapLine $result]"
    } elseif {$status eq {timeout}} {
      # A TODO unit that timed out is still an expected failure
      if {$todo eq {}} { incr failed }
      Say "not ok $id - $name$directive"
      Say {  ---}
      Say {  message: |}
      foreach line [split [CleanTapLine $result] \n] { Say "    $line" }
      Say {  ...}
    } else {
      # A TODO failure is an expected one: reported, but not counted against the verdict
      if {$todo eq {}} { incr failed }
      Say "not ok $id - $name$directive"
      if {[dict exists $options -errorinfo]} {
        set message [TrimTrace [dict get $options -errorinfo] $name]
      } elseif {$result ne {}} {
        set message $result
      } else {
        set message {unit failed}
      }
      set message [string trimright $message " \t\n"]
      Say {  ---}
      Say {  message: |}
      foreach line [split $message \n] { Say "    $line" }
      Say {  ...}
    }
    # The channel dumps for the failed units (all of them under -F)
    if {$verbose && ($full || $status eq {error}) && ([llength $stdout] || [llength $stderr])} {
      puts stderr {}
      puts stderr "- $name"
      if {[llength $stdout]} {
        puts stderr "-- stdout:"
        foreach line $stdout { puts stderr $line }
      }
      if {[llength $stderr]} {
        puts stderr "-- stderr:"
        foreach line $stderr { puts stderr $line }
      }
    }
    # The per-unit logs: the retained garbage documents the run
    if {!$cleanup && ([llength $stdout] || [llength $stderr])} {
      set tag $name
      regsub -all {\W} $tag {_} tag
      set dir [expr {$stage ne {false} ? $stage : $origin}]
      foreach {chan data} [list stdout $stdout stderr $stderr] {
        if {![llength $data]} {continue}
        try {
          set f [open [file join $dir $id-$tag-$chan.out] w]
          try {
            foreach line $data { puts $f $line }
          } finally {
            close $f
          }
        } on error {} {}
      }
    }
  }

  # Format a single unit test line and its diagnostics for nested output
  proc FormatUnitLine {depth localId id} {
    variable units
    variable unitOutcome
    variable full
    set indent [string repeat " " [expr {$depth * 4}]]
    lassign [dict get $units $id] name skip todo
    set name [TapDescription $name]
    set skip [CleanTapLine $skip]
    set todo [CleanTapLine $todo]
    set lines [list]
    if {$skip ne {}} {
      lappend lines "${indent}ok $localId - $name # SKIP $skip"
      return $lines
    }
    lassign [dict get $unitOutcome $id] status result options stdout stderr
    set directive {}
    if {$todo ne {}} { set directive " # TODO $todo" }
    if {$status eq {ok}} {
      lappend lines "${indent}ok $localId - $name$directive"
    } elseif {$status eq {skipped}} {
      lappend lines "${indent}ok $localId - $name # SKIP [CleanTapLine $result]"
    } elseif {$status eq {timeout}} {
      lappend lines "${indent}not ok $localId - $name$directive"
      lappend lines "${indent}  ---"
      lappend lines "${indent}  message: |"
      foreach mline [split [CleanTapLine $result] \n] {
        lappend lines "${indent}    $mline"
      }
      lappend lines "${indent}  ..."
    } else {
      lappend lines "${indent}not ok $localId - $name$directive"
      if {[dict exists $options -errorinfo]} {
        set message [TrimTrace [dict get $options -errorinfo] $name]
      } elseif {$result ne {}} {
        set message $result
      } else {
        set message {unit failed}
      }
      set message [string trimright $message " \t\n"]
      lappend lines "${indent}  ---"
      lappend lines "${indent}  message: |"
      foreach mline [split $message \n] {
        lappend lines "${indent}    $mline"
      }
      lappend lines "${indent}  ..."
    }
    return $lines
  }

  # Format an entire scope and all its children for nested output
  proc FormatScopeLines {s} {
    variable scopes
    variable scopeFailed
    set depth [dict get $scopes $s depth]
    set name [CleanTapLine [dict get $scopes $s name]]
    set items [dict get $scopes $s items]
    set indent [string repeat " " [expr {$depth * 4}]]
    set parentIndent [string repeat " " [expr {($depth - 1) * 4}]]
    set lines [list]
    if {$depth > 0} {
      lappend lines "${parentIndent}# Subtest: $name"
    }
    set count [llength $items]
    if {$count > 0} {
      lappend lines "${indent}1..$count"
    } else {
      lappend lines "${indent}1..0 # SKIP no units discovered"
    }
    set localId 0
    foreach item $items {
      incr localId
      lassign $item kind id
      if {$kind eq {unit}} {
        set ulines [FormatUnitLine $depth $localId $id]
        foreach ul $ulines { lappend lines $ul }
      } else {
        set slines [FormatScopeLines $id]
        foreach sl $slines { lappend lines $sl }
        set childFailed 0
        if {[dict exists $scopeFailed $id] && [dict get $scopeFailed $id]} {
          set childFailed 1
        }
        set childName [TapDescription [dict get $scopes $id name]]
        set childSkip [CleanTapLine [dict get $scopes $id skip]]
        set childTodo [CleanTapLine [dict get $scopes $id todo]]
        if {$childSkip ne {}} {
          lappend lines "${indent}ok $localId - $childName # SKIP $childSkip"
        } else {
          set cdirective {}
          if {$childTodo ne {}} { set cdirective " # TODO $childTodo" }
          if {$childFailed && $childTodo eq {}} {
            lappend lines "${indent}not ok $localId - $childName$cdirective"
          } else {
            lappend lines "${indent}ok $localId - $childName$cdirective"
          }
        }
      }
    }
    return $lines
  }

  # Print the ready prefix of the nested roster (TAP 14)
  proc FlushNested {} {
    variable scopes
    variable nextTop
    variable unitOutcome
    variable scopeFailed
    set items [dict get $scopes 0 items]
    set total [llength $items]
    while {$nextTop <= $total} {
      set item [lindex $items [expr {$nextTop - 1}]]
      lassign $item kind id
      if {$kind eq {unit}} {
        if {![dict exists $unitOutcome $id]} {
          break
        }
        set lines [FormatUnitLine 0 $nextTop $id]
        foreach line $lines { Say $line }
        incr nextTop
      } else {
        if {[dict get $scopes $id pending] > 0} {
          break
        }
        set lines [FormatScopeLines $id]
        foreach line $lines { Say $line }
        set childFailed 0
        if {[dict exists $scopeFailed $id] && [dict get $scopeFailed $id]} {
          set childFailed 1
        }
        set childName [TapDescription [dict get $scopes $id name]]
        set childSkip [CleanTapLine [dict get $scopes $id skip]]
        set childTodo [CleanTapLine [dict get $scopes $id todo]]
        if {$childSkip ne {}} {
          Say "ok $nextTop - $childName # SKIP $childSkip"
        } else {
          set cdirective {}
          if {$childTodo ne {}} { set cdirective " # TODO $childTodo" }
          if {$childFailed && $childTodo eq {}} {
            Say "not ok $nextTop - $childName$cdirective"
          } else {
            Say "ok $nextTop - $childName$cdirective"
          }
        }
        incr nextTop
      }
    }
  }

  # Print the ready prefix of the roster; the TAP 13 dialect requires ascending
  # test numbers, so out-of-order completions are held back until their turn comes
  proc Flush {} {
    variable inbox
    variable next
    while {[dict exists $inbox $next]} {
      lassign [dict get $inbox $next] status result options stdout stderr
      dict unset inbox $next
      Emit $next $status $result $options $stdout $stderr
      incr next
    }
  }

  # Stash an outcome until the plan has been announced. In the TAP 14 dialect
  # the test points may then come in any order within the plan range, so the outcomes
  # stream out as they arrive; in the TAP 13 dialect ascending numbers are required,
  # so an outcome waits until all the lower-numbered units have been reported
  proc Deliver {id status result options stdout stderr} {
    variable inbox
    variable streaming
    variable tap
    variable nested
    variable unitOutcome
    variable unitScope
    variable scopes
    variable scopeFailed
    variable passed
    variable failed
    variable verbose
    variable full
    variable cleanup
    variable stage
    variable origin
    variable units
    if {$nested} {
      lassign [dict get $units $id] name skip todo
      # The channel dumps for the failed units (all of them under -F)
      if {$verbose && ($full || $status eq {error}) && ([llength $stdout] || [llength $stderr])} {
        puts stderr {}
        puts stderr "- $name"
        if {[llength $stdout]} {
          puts stderr "-- stdout:"
          foreach line $stdout { puts stderr $line }
        }
        if {[llength $stderr]} {
          puts stderr "-- stderr:"
          foreach line $stderr { puts stderr $line }
        }
      }
      # The per-unit logs: the retained garbage documents the run
      if {!$cleanup && ([llength $stdout] || [llength $stderr])} {
        set tag $name
        regsub -all {\W} $tag {_} tag
        set dir [expr {$stage ne {false} ? $stage : $origin}]
        foreach {chan data} [list stdout $stdout stderr $stderr] {
          if {![llength $data]} {continue}
          try {
            set f [open [file join $dir $id-$tag-$chan.out] w]
            try {
              foreach line $data { puts $f $line }
            } finally {
              close $f
            }
          } on error {} {}
        }
      }
      if {$skip ne {} || $status eq {ok} || $status eq {skipped}} {
        incr passed
      } else {
        if {$todo eq {}} { incr failed }
      }
      dict set unitOutcome $id [list $status $result $options $stdout $stderr]
      set scope [dict get $unitScope $id]
      if {$status eq {error} && $todo eq {}} {
        dict set scopeFailed $scope 1
        set p [dict get $scopes $scope parent]
        while {$p >= 0} {
          dict set scopeFailed $p 1
          set p [dict get $scopes $p parent]
        }
      }
      dict update scopes $scope s { dict incr s pending -1 }
      set p [dict get $scopes $scope parent]
      while {$p >= 0} {
        dict update scopes $p ps { dict incr ps pending -1 }
        set p [dict get $scopes $p parent]
      }
      if {$streaming} {
        FlushNested
      }
      return
    }
    if {$tap >= 14 && $streaming} {
      Emit $id $status $result $options $stdout $stderr
    } else {
      dict set inbox $id [list $status $result $options $stdout $stderr]
      if {$streaming} { Flush }
    }
  }

  # The premature termination: the queued units are cancelled, the in-flight ones
  # are drained silently (their results are discarded) and the run leaves
  # with the failure status
  proc Bailout {} {
    variable pool
    variable pending
    variable serial
    variable serialQueue
    if {$serial} {
      set serialQueue [list]
      return
    }
    foreach job [tpool::cancel $pool [dict keys $pending]] {
      dict unset pending $job
    }
    while {[dict size $pending] > 0} {
      foreach job [tpool::wait $pool [dict keys $pending]] {
        dict unset pending $job
        catch {tpool::get $pool $job}
      }
    }
  }

  # Makes a directory tree writable (clears read-only flags on Windows, sets 0755/0644 on Unix)
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

  # The common tail: the suite interpreters go away, the workers wind down,
  # the managed staging directory is removed unless the garbage is retained
  proc Teardown {} {
    variable boxes
    variable pool
    variable serial
    variable staging
    variable stage
    variable origin
    variable cleanup
    variable verbose
    foreach box $boxes { catch {interp delete $box} }
    if {!$serial && $pool ne {}} { catch {tpool::release $pool} }
    if {$staging && $stage ne {false} && $cleanup && $stage ne [pwd] && $stage ne $origin} {
      MakeWritable $stage
      if {[catch {file delete -force -- $stage}]} {
        if {$verbose} {puts stderr "failed to remove temporary directory $stage, spawning watchdog"}
        SpawnWatchdog $stage
      } elseif {$verbose} {
        puts stderr "removed temporary directory $stage"
      }
    }
  }

  # The TAP stream starts here; the header must be the first line of the output.
  # Suite code writing to stdout during discovery is tolerated by the consumers
  # as unknown lines occurring between the header and the plan
  Say "TAP version $tap"
  Say "# testme $version"

  # Rerun this toplevel script as a nested suite; the discovery cascades synchronously
  # (suites submit units without waiting for their outcomes), so the whole tree
  # and the total unit count are known by the return.
  # Under the bailout policy a failing suite script aborts the discovery right away.
  # The queued units are cancelled and the suspended pool is resumed before the teardown,
  # for a pool holding queued jobs cannot be released
  if {[catch {Box [dict get $Context -root] [file tail $::argv0]} err opts]} {
    if {!$quiet || $verbose} { puts stderr $err }
    if {!$serial} {
      foreach x [tpool::cancel $pool [dict keys $pending]] {
        dict unset pending $x
      }
      tpool::resume $pool
    }
    Teardown
    Say {Bail out!}
    exit 1
  }

  # The plan: the total is known once the whole tree has been submitted;
  # the skip-all form covers the empty roster
  if {$nested} {
    set topCount [llength [dict get $scopes 0 items]]
    if {$topCount > 0} {
      Say "1..$topCount"
    } else {
      Say "1..0 # SKIP no units discovered"
    }
  } elseif {$index > 0} {
    Say "1..$index"
  } else {
    Say "1..0 # SKIP no units discovered"
  }

  # Enter execute phase: drain the pool reporting the outcomes as they come.
  # The submission phase is over, so the pending set only shrinks.
  # The outcomes stashed during discovery (skipped units, failed suites) join the stream now.
  # One environment snapshot serves the whole run: taken here, after discovery,
  # it still carries whatever the suites adjusted in ::env while they were
  # collected, while saving every worker the lock-guarded ::env rebuild
  set envSnapshot [array get ::env]
  if {!$serial} {
    catch {tsv::set ::testme env $envSnapshot}
  }
  set streaming 1
  if {$nested} {
    FlushNested
  } elseif {$tap >= 14} {
    foreach id [lsort -integer [dict keys $inbox]] {
      lassign [dict get $inbox $id] status result options stdout stderr
      dict unset inbox $id
      Emit $id $status $result $options $stdout $stderr
    }
  } else {
    Flush
  }
  if {$serial} {
    foreach item $serialQueue {
      if {$doomed} { break }
      lassign $item id record paths ver
      if {[catch {RunUnit $record $paths $ver $envSnapshot $timeout} outcome]} {
        set outcome [list error $outcome {} {} {}]
      }
      if {$doomed} { continue }
      lassign $outcome status result options stdout stderr
      Deliver $id $status $result $options $stdout $stderr
      if {$premature && $failed > 0} {
        set doomed 1
      }
    }
  } else {
    tpool::resume $pool
    while {[dict size $pending] > 0 && !$doomed} {
      # tpool::wait blocks until at least one listed job completes
      # and returns the list of the completed handles;
      # each handle must be reaped with tpool::get and dropped from the wait list at once
      foreach job [tpool::wait $pool [dict keys $pending]] {
        set id [dict get $pending $job]
        dict unset pending $job
        # The worker packs the unit outcome; a catch failure here means the runner machinery itself broke
        if {[catch {tpool::get $pool $job} outcome]} {
          set outcome [list error $outcome {} {} {}]
        }
        if {$doomed} { continue }
        lassign $outcome status result options stdout stderr
        Deliver $id $status $result $options $stdout $stderr
        if {$premature && $failed > 0} {
          # The first failure triggers Bailout to cancel queued units and drain in-flight ones
          set doomed 1
        }
      }
    }
  }
  if {$doomed} { Bailout }

  Teardown

  if {$doomed} {
    Say {Bail out!}
    exit 1
  }
  if {!$quiet} { puts stderr "testme: $passed passed, $failed failed" }
  # Prevent the user's code following the `package require testme` from being reached:
  # the whole script has already run inside the suite interpreter
  exit [expr {$failed > 0}]

}


}
