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


      ### CLIP code


      package require Tcl 8.6


      namespace eval ::clip {


        # defs: { { opt(s) } -slot opt -default value -info "text" -section {common} -apply {script} }
        proc parse {argv defs} {
          set x [lsearch $argv --]
          if {$x < 0} {
            set opts $argv
            set args {}
          } else {
            set opts [lrange $argv 0 [expr {$x-1}]]
            set args [lrange $argv [expr {$x+1}] end]
          }
          set xargs {}
          lassign [NormalizeDefs $defs] short_flags short_opts long_flags long_opts
          set flagset [dict create]
          foreach f $short_flags {
            dict set flagset [dict get $f bare] $f
          }
          while {[llength $opts]} {
            set x [Next opts]
            # long option with inline value, ex. --abc=123
            if {[regexp {^-+([[:alnum:]][[:alnum:]\-\_]*)=(.*)$} $x ~ tag value]} {
              set found 0
              foreach d $long_opts {
                dict with d {
                  if {$tag == $bare} {
                    set found 1
                    break
                  }
                }
              }
              if {$found} {
                apply $apply $slot $value
                continue
              } else {
                error "unrecognized option in $x"
              }
            }
            # long/short option expecting separate value, ex. --abc 123
            if {[regexp {^-+([[:alnum:]][[:alnum:]\-\_]*)} $x ~ tag]} {
              set found 0
              foreach d [concat $long_opts $short_opts] {
                dict with d {
                  if {$tag == $bare} {
                    set value [Next opts]
                    set found 1
                    break
                  }
                }
              }
              if {$found} {
                apply $apply $slot $value
                continue
              }
            }
            # long/short separate flag, ex. -C,  --create
            if {[regexp {^-+([[:alnum:]][[:alnum:]\-\_]*)} $x ~ tag]} {
              set found 0
              foreach d [concat $long_flags $short_flags] {
                dict with d {
                  if {$tag == $bare} {
                    set value $default
                    set found 1
                    break
                  }
                }
              }
              if {$found} {
                apply $apply $slot $value
                continue
              }
            }
            # short flag within the coalesced flag set, ex. -Sxy
            if {[regexp {^-([[:alnum:]]+)$} $x ~ flags]} {
              foreach flag [split $flags {}] {
                try {
                  set d [dict get $flagset $flag]
                  dict with d {
                    apply $apply $slot $default
                  }
                } on error {} {
                  error "unrecognized short flag -$flag"
                }
              }
              continue
            }
            # stray -flag
            if {[regexp {^-.*} $x]} {
              error "unrecognized argument $x"
            }
            # the rest arguments are passed through
            lappend xargs $x
          }
          concat $xargs $args
        }


        #
        proc usage {defs {sections {}} {chan stdout}} {
          set padding [ComputePadding $defs]
          dict for {section info} $sections {
            PrintSection [ExtractSectionDefs defs $section] $info $chan $padding
          }
          PrintSection $defs "Generic options" $chan $padding
        }


        proc ComputePadding {defs} {
          set pad 0
          foreach def $defs {
            set x [string length [FormatOpts [Opts $def]]]
            if {$x > $pad} { set pad $x }
          }
          return $pad
        }


        proc ExtractSectionDefs {defsVar section} {
          upvar $defsVar defs
          set rest [list]
          set filtered [list]
          foreach def $defs {
            if {[Section $def] == $section} {
              lappend filtered $def
            } else {
              lappend rest $def
            }
          }
          set defs $rest
          return $filtered
        }


        proc FormatOpts {opts} {
          set arg 0
          set x [lmap opt $opts {
            regexp {(.*?)(=*)$} $opt ~ bare flag
            if {!$arg && $flag != {}} { set arg 1 }
            subst $bare
          }]
          set x [join $x {, }]
          if {$arg} { set x "$x <arg>" }
          return $x
        }


        proc PrintSection {defs info chan padding} {
          if {[llength $defs]} {
            incr padding 2
            if {$info != {}} { puts $chan "\n* $info:\n" }
            foreach def $defs {
              set opts [format %${padding}s [FormatOpts [Opts $def]]]
              puts $chan "$opts    [Info $def]"
            }
          }
        }


        proc Opts {def} { lindex $def 0 }


        proc Dict {def} { lrange $def 1 end }

        
        proc Default {def} {
          try { return [dict get [Dict $def] -default] } on error {} { return 1 }
        }
        
        
        proc Section {def} {
          try { return [dict get [Dict $def] -section] } on error {} { return {} }
        }


        proc Info {def} {
          try { return [dict get [Dict $def] -info] } on error {} { return {} }
        }


        proc Slot {def} {
          try { return [dict get [Dict $def] -slot] } on error {} { return {} }
        }


        proc Apply {def} {
          try { return [list {slot value} [dict get [Dict $def] -apply]] } on error {} { return {{slot value} { upvar 2 $slot x; set x $value }} }
        }


        proc Next {listVar} {
          upvar $listVar list
          if {![llength $list]} { error "not enough arguments" }
          set v [lindex $list 0]
          set list [lrange $list 1 end]
          return $v
        }


        # Flags are the parameterless options which receive 1 value when set, ex. -S
        # Single letter flags may be coalesced, ex. -Sxyz
        # Multi letter flags must come on their own, ex. -foo
        proc NormalizeDefs {defs} {
          set short_flags {}
          set short_opts {}
          set long_flags {}
          set long_opts {}
          foreach def $defs {
            set slot [Slot $def]
            foreach opt [Opts $def] {
              regexp -- {-+(.*?)=?} $opt ~ bare
              if {$slot == {}} { set slot $bare }
              switch -regexp $opt {
                {^-[[:alnum:]]$} { set kind short_flags }
                {^-+[[:alnum:]][[:alnum:]\-\_]*$} { set kind long_flags }
                {^-[[:alnum:]]=$} { set kind short_opts }
                {^-+[[:alnum:]][[:alnum:]\-\_]*=$} { set kind long_opts }
                default { error "failed to decode option descriptor $opt" }
              }
              lappend $kind [dict create bare $bare slot $slot default [Default $def] apply [Apply $def] info [Info $def] section [Section $def]]
            }
          }
          return [list $short_flags $short_opts $long_flags $long_opts]
        }


      }


      set cli {
        {{-h --help} -info "print help" -apply {
          puts stderr "usage: $::argv0 {-f --flag --opt=arg --opt arg ...} {--} {tag +tag -tag ...}\n\n+tag | tag     instruct to execute only units with specified tag(s)\n-tag           instruct skip units with specified tag(s)"
          clip::usage $testme::cli {} stderr
          exit 0
        }}
        {{--version} -info "print Testme code version" -apply {
          puts stderr [package require testme]
          exit 0
        }}
      }


      if {[llength $argv]} {set argv [clip::parse $argv $cli]}


      set +tags [list]
      set -tags [list]


      foreach arg $argv {
        switch -glob $arg {
          +* {lappend +tags [string trimleft $arg +]}
          -* {lappend -tags [string trimleft $arg -]}
          default {lappend +tags $arg}
        }
      }


      set ::nesting -1


      ### Execution thread code


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


      variable skipped [list]


      variable units [dict create]


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
        set s [llength $args]
        if {$s < 1 || $s % 2 == 0} {error "usage: testme::unit ?-name ...? ?-tags ...? {...}"}
        set opts [lrange $args 0 end-1]
        set code [lindex [lrange $args end end] 0]
        set name unit[llength $pending]
        set tags [list]
        catch {set name [dict get $opts -name]}
        catch {set tags [dict get $opts -tags]}
        set n [dict size $units]; incr n
        dict set units $n [dict create -name $name -tags $tags -code $code -id $n]
        if {([llength ${+tags}] == 0 || [llength [intersection ${+tags} $tags]] > 0) && [llength [intersection ${-tags} $tags]] == 0} {
          lappend pending [tpool::post $executor "execute {$code}"]
        } else {
          lappend skipped $n
        }
      }


      Import $argv0


      puts "TAP version 14"
      puts "1..[dict size $units]"


      foreach n $skipped {
        set name [dict get [dict get $units $n] -name]
        set id [dict get [dict get $units $n] -id]
        puts "ok $id - $name # SKIP due to tagging"
      }


# FIXME duplicate reports on skipped (excluded) units


      while {[llength $pending]} {
        set finished [tpool::wait $executor $pending pending]
        foreach n $finished {
          set pending [lsearch -inline -all -not -exact $pending $n]
          set name [dict get [dict get $units $n] -name]
          set id [dict get [dict get $units $n] -id]
          set return [tpool::get $executor $n]
          if {[dict get $return -code] == 0} {
            puts "ok $id - $name"
          } else {
            puts "not ok $id - $name"
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