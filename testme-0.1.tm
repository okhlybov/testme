package require Tcl 8.6-


namespace eval ::testme {


# The same source presents a different face at every level of the suite tree:
# the toplevel face (no ::testme::Context yet) is the driver owning the thread pool;
# the nested face (the context pre-seeded by the driver) is the per-suite unit command.
# Recursion is thereby accounted for: the driver reruns the toplevel script itself
# as a nested suite, and every deeper level is just another nested suite.
if {[info exists Context]} { set context {nested} } else { set context {toplevel} }


### Nested context: the per-suite face
if {$context eq {nested}} {

  # Declare a unit of work. The submission is immediate - a parametrization cycle
  # is expected to submit the whole series before any unit starts running -
  # and the returned ticket is the unit number in the TAP plan.
  # The submission crosses the interpreter boundary through the ::testme::submit
  # alias planted by the driver
  proc unit {args} {
    set nargs [llength $args]
    if {$nargs < 1 || $nargs % 2 == 0} {error "usage: testme::unit ?-name ...? ?-tags ...? ?-skip reason? ?-todo reason? {code...}"}
    set opts [lrange $args 0 end-1]
    set code [lindex $args end]
    return [::testme::submit $opts $code]
  }

  namespace export unit
  catch {namespace eval :: {namespace import ::testme::unit}}

}


### Toplevel context: the driver face
if {$context eq {toplevel}} {

  package require Thread

  # A bare require (an interactive shell, a sourced snippet) has no suite script to rerun;
  # refuse it with a catchable error instead of mistaking the shell itself for a suite
  if {![info exists ::argv0] || $::argv0 eq {} ||
      [file normalize $::argv0] eq [file normalize [info nameofexecutable]] ||
      ![file isfile [file normalize $::argv0]]} {
    error {testme package must be required by a script (invalid ::argv0)}
  }

  # The module version is carried by the file name
  set version 0
  regexp -- {-(\d+(?:\.\d+)*)$} [file rootname [file tail [info script]]] -> version

  # The driver command line is consumed by the clip parser;
  # -j/--jobs overrides the worker count, -t/--tap selects the TAP dialect
  # (14 streams the test points in completion order for the real-time progress,
  # 13 orders them strictly for the older consumers);
  # the trailing arguments are the tag filters: +tag (or a bare word) selects
  # the units carrying the tag, -tag deselects them; -- ends the options
  # so the filters may look like ones
  variable jobs 0
  variable tap 0
  variable include [list]
  variable exclude [list]
  if {[catch {
    package require clip
    set opts {
      {{--jobs= -j=} -info "set maximum number of parallel units" -default 0 -slot jobs}
      {{--tap=} -info "emit the TAP version: 14 (streamed) or 13 (strictly ordered)" -default 14 -slot tap}
      {{-h --help} -info "print help" -apply {
        puts stderr "usage: $::argv0 \[-j jobs\] \[--tap 13|14\] \[--\] \[+tag ...\] \[-tag ...\] \[tag ...\]"
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
    set filters [clip::parse $::argv $opts]
  } err]} {
    puts stderr $err
    exit 1
  }
  if {$jobs != 0 && (![string is integer -strict $jobs] || $jobs <= 0)} {
    puts stderr "testme: invalid job count: $jobs"
    exit 1
  }
  if {$tap == 0} {
    # The TESTME_TAP environment variable is the fallback beneath the command line
    if {[info exists ::env(TESTME_TAP)] && $::env(TESTME_TAP) == 13} { set tap 13 } else { set tap 14 }
  }
  if {$tap != 13 && $tap != 14} {
    puts stderr "testme: unsupported TAP version: $tap"
    exit 1
  }
  foreach arg $filters {
    switch -glob -- $arg {
      +* { lappend include [string trimleft $arg +] }
      -* { lappend exclude [string trimleft $arg -] }
      default { lappend include $arg }
    }
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

  # The worker count is sized after the machine; the command line -j takes precedence,
  # then the TESTME_JOBS environment variable, then the platform detection
  proc CoreCount {} {
    if {[info exists ::env(TESTME_JOBS)] && [string is integer -strict $::env(TESTME_JOBS)] && $::env(TESTME_JOBS) > 0} {
      return $::env(TESTME_JOBS)
    }
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

  # Idle workers must exist up front: pools relying on lazy worker spawning
  # were observed to dispatch queued jobs one at a time, defeating parallelism
  variable cores [expr {$jobs > 0 ? $jobs : [CoreCount]}]
  variable pool [tpool::create -minworkers $cores -maxworkers $cores]
  variable pending [dict create]
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

  # Enter submit phase: the units accumulate while the suite tree is being discovered
  tpool::suspend $pool

  # Seed the context for rerunning this very script as a nested suite
  set Context [dict create \
    -root [file dirname [file normalize $argv0]] \
    -script [file tail $::argv0] \
     tcl::tm::path [tcl::tm::path list] \
  ]

  # The worker-side unit runner: a self-contained apply so the worker thread needs no setup.
  # The unit code runs in a clean interpreter which is destroyed right after
  variable worker {{code} {
    set u [interp create]
    try {
      # Unit code must not terminate the process; the attempt is reported as a failure
      interp eval $u {proc exit {args} {return -code error {testme: unit attempted to exit}}}
      set result [interp eval $u $code]
      set status ok
      set options {}
    } on error {result options} {
      set status error
    } finally {
      interp delete $u
    }
    return [list $status $result $options]
  }}

  # A display name for synthetic units: the path relative to the suite root when possible
  proc Relative {path} {
    variable Context
    set prefix [file normalize [dict get $Context -root]]/
    if {[string first $prefix $path] == 0} {
      return [string range $path [string length $prefix] end]
    }
    return $path
  }

  # The shared elements of two lists
  proc Intersect {a b} {
    set r {}
    foreach x $a {
      if {[lsearch -exact $b $x] >= 0 && [lsearch -exact $r $x] < 0} { lappend r $x }
    }
    return $r
  }

  # Receive a unit submission from a suite (through the ::testme::submit alias);
  # the ticket returned to the submitting suite is the unit number in the TAP plan
  proc Submit {box opts code} {
    variable pool
    variable pending
    variable worker
    variable index
    variable units
    variable include
    variable exclude
    set name {}; set skip {}; set todo {}
    if {[dict exists $opts -name]} { set name [dict get $opts -name] }
    if {[dict exists $opts -skip]} { set skip [dict get $opts -skip] }
    if {[dict exists $opts -todo]} { set todo [dict get $opts -todo] }
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
    if {$skip ne {}} {
      # A skipped unit is planned but never run
      Deliver $index ok {} {}
      return $index
    }
    set job [tpool::post -nowait $pool [list apply $worker $code]]
    dict set pending $job $index
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
    Descend $root
  }

  # Create an isolated suite interpreter over $root and run the script there;
  # the unit submissions arrive synchronously through the alias
  proc Box {root} {
    variable Context
    variable boxes
    variable nboxes
    variable ran
    variable index
    variable units
    # The double execution guard: a script that has already run in this process
    # (composed by an umbrella, aliased by a symlink, discovered twice) is never rerun
    set identity [Identity [file normalize [file join $root [dict get $Context -script]]]]
    if {[dict exists $ran $identity]} { return }
    dict set ran $identity 1
    set box [interp create suite[incr nboxes]]
    lappend boxes $box
    set script [file join $root [dict get $Context -script]]
    if {[catch {
      # Seed the augmented context so the module takes its nested face when required
      $box eval {namespace eval ::testme {}}
      $box eval [list set ::testme::Context [dict merge $Context [dict create -root $root]]]
      # Propagate the module lookup paths so `package require testme` resolves the same copy
      $box eval {
        set current [tcl::tm::path list]
        foreach x [lreverse [dict get $::testme::Context tcl::tm::path]] {
          # Squash duplicates in the module lookup path
          if {[lsearch $current $x] < 0} { tcl::tm::path add $x }
        }
      }
      # The unit submissions cross the interpreter boundary through this alias
      interp alias $box ::testme::submit {} ::testme::Submit $box
      # Suite code must not terminate the process either
      $box eval {proc exit {args} {return -code error {testme: suite attempted to exit}}}
      # Trace whatever the suite composes by sourcing (the umbrella trail):
      # the trail is harvested at completion to feed the double execution guard
      $box eval {
        rename source ::testme::source
        proc source {args} {
          if {[llength $args]} {
            catch {lappend ::testme::sourced [file normalize [lindex $args end]]}
          }
          uplevel 1 [linsert $args 0 ::testme::source]
        }
      }
      # Run the suite script; its unit submissions post to the suspended pool right away
      $box eval [list source $script]
    } err]} {
      # A failed suite script becomes a synthetic failed unit so the roster stays honest
      incr index
      dict set units $index [list [Relative [file normalize $script]] {} {}]
      Deliver $index error "suite script failed: $err" {}
    }
    Retire $box $root
  }

  # Look for the scripts sharing the name with the current one
  # in the immediate subdirectories of $root; called once a suite script has finished,
  # so the scripts it composed by sourcing are known before discovery reaches them;
  # deeper levels are reached through the completion of the immediate ones
  proc Descend {root} {
    variable Context
    foreach source [glob -nocomplain -directory $root [file join * [dict get $Context -script]]] {
      Box [file dirname [file normalize $source]]
    }
  }

  # Print a single TAP test line with its directives and, for a failure, a YAML diagnostic
  proc Emit {id status result options} {
    variable units
    variable passed
    variable failed
    lassign [dict get $units $id] name skip todo
    if {$skip ne {}} {
      incr passed
      puts "ok $id - $name # SKIP $skip"
      return
    }
    set directive {}
    if {$todo ne {}} { set directive " # TODO $todo" }
    if {$status eq {ok}} {
      incr passed
      puts "ok $id - $name$directive"
    } else {
      # A TODO failure is an expected one: reported, but not counted against the verdict
      if {$todo eq {}} { incr failed }
      puts "not ok $id - $name$directive"
      if {[dict exists $options -errorinfo]} {
        set message [dict get $options -errorinfo]
      } elseif {$result ne {}} {
        set message $result
      } else {
        set message {unit failed}
      }
      set message [string trimright $message " \t\n"]
      puts {  ---}
      puts {  message: |}
      foreach line [split $message \n] { puts "    $line" }
      puts {  ...}
    }
  }

  # Print the ready prefix of the roster; the TAP 13 dialect requires ascending
  # test numbers, so out-of-order completions are held back until their turn comes
  proc Flush {} {
    variable inbox
    variable next
    while {[dict exists $inbox $next]} {
      lassign [dict get $inbox $next] status result options
      dict unset inbox $next
      Emit $next $status $result $options
      incr next
    }
  }

  # Stash an outcome until the plan has been announced. In the TAP 14 dialect
  # the test points may then come in any order within the plan range, so the outcomes
  # stream out as they arrive; in the TAP 13 dialect ascending numbers are required,
  # so an outcome waits until all the lower-numbered units have been reported
  proc Deliver {id status result options} {
    variable inbox
    variable streaming
    variable tap
    if {$tap >= 14 && $streaming} {
      Emit $id $status $result $options
    } else {
      dict set inbox $id [list $status $result $options]
      if {$streaming} { Flush }
    }
  }

  # The TAP stream starts here; the header must be the first line of the output.
  # Suite code writing to stdout during discovery is tolerated by the consumers
  # as unknown lines occurring between the header and the plan
  puts "TAP version $tap"
  puts "# testme $version"

  # Rerun this toplevel script as a nested suite; the discovery cascades synchronously
  # (suites submit units without waiting for their outcomes), so the whole tree
  # and the total unit count are known by the return
  Box [dict get $Context -root]

  # The plan: the total is known once the whole tree has been submitted;
  # the skip-all form covers the empty roster
  if {$index > 0} {
    puts "1..$index"
  } else {
    puts "1..0 # SKIP no units discovered"
  }

  # Enter execute phase: drain the pool reporting the outcomes as they come.
  # The submission phase is over, so the pending set only shrinks.
  # The outcomes stashed during discovery (skipped units, failed suites) join the stream now
  set streaming 1
  if {$tap >= 14} {
    foreach id [lsort -integer [dict keys $inbox]] {
      lassign [dict get $inbox $id] status result options
      dict unset inbox $id
      Emit $id $status $result $options
    }
  } else {
    Flush
  }
  tpool::resume $pool
  while {[dict size $pending] > 0} {
    # tpool::wait blocks until at least one listed job completes
    # and returns the list of the completed handles;
    # each handle must be reaped with tpool::get and dropped from the wait list at once
    foreach job [tpool::wait $pool [dict keys $pending]] {
      set id [dict get $pending $job]
      dict unset pending $job
      # The worker packs the unit outcome; a catch failure here means the runner machinery itself broke
      if {[catch {tpool::get $pool $job} outcome]} {
        set outcome [list error $outcome {}]
      }
      lassign $outcome status result options
      Deliver $id $status $result $options
    }
  }

  # Cleanup
  foreach box $boxes { catch {interp delete $box} }
  tpool::release $pool

  puts stderr "testme: $passed passed, $failed failed"
  # Prevent the user's code following the `package require testme` from being reached:
  # the whole script has already run inside the suite interpreter
  exit [expr {$failed > 0}]

}


}
