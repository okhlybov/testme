# clip - a command line parser for Tcl
# https://github.com/okhlybov/testme


package require Tcl 8.6-


namespace eval ::clip {


  # defs: { { opt(s) } -slot opt -default value -info "text" -section {common} -apply {script} }
  proc parse {argv defs} {
    lassign [NormalizeDefs $defs] short_flags short_opts long_flags long_opts
    set flagset [dict create]
    foreach f $short_flags {
      dict set flagset [dict get $f bare] $f
    }
    set optset [dict create]
    foreach o $short_opts {
      dict set optset [dict get $o bare] $o
    }
    set xargs {}
    set opts $argv
    while {[llength $opts]} {
      set x [lindex $opts 0]
      set opts [lrange $opts 1 end]
      # option terminator: everything that follows is positional,
      # recognized only here, never by the argv pre-scan
      if {$x eq "--"} {
        lappend xargs {*}$opts
        break
      }
      # a lone dash is positional, ex. the conventional stdin/stdout marker
      if {$x eq "-"} {
        lappend xargs $x
        continue
      }
      # option with inline value, ex. --abc=123, -n=5
      if {[regexp {^--?([[:alnum:]][[:alnum:]\-\_]*)=(.*)$} $x ~ tag value]} {
        if {[set d [FindDef [concat $long_opts $short_opts] $tag]] ne {}} {
          apply [dict get $d apply] [dict get $d slot] $value
          continue
        }
        if {[FindDef [concat $long_flags $short_flags] $tag] ne {}} {
          error "option [string range $x 0 [expr {[string first = $x]-1}]] takes no value"
        }
        error "unrecognized option in $x"
      }
      # long/short option expecting separate value, ex. --abc 123
      if {[regexp {^--?([[:alnum:]][[:alnum:]\-\_]*)$} $x ~ tag]} {
        if {[set d [FindDef [concat $long_opts $short_opts] $tag]] ne {}} {
          if {![llength $opts]} { error "missing value for option $x" }
          apply [dict get $d apply] [dict get $d slot] [lindex $opts 0]
          set opts [lrange $opts 1 end]
          continue
        }
      }
      # long/short separate flag, ex. -C,  --create
      if {[regexp {^--?([[:alnum:]][[:alnum:]\-\_]*)$} $x ~ tag]} {
        if {[set d [FindDef [concat $long_flags $short_flags] $tag]] ne {}} {
          apply [dict get $d apply] [dict get $d slot] [dict get $d default]
          continue
        }
      }
      # short flags within the coalesced flag set, ex. -Sxy; the first
      # option met in the set consumes the rest of the token as its
      # value, ex. -oFILE
      if {[regexp {^-([[:alnum:]]+)$} $x ~ flags]} {
        # a leading digit reads as a negative number, ex. -3
        if {[string is digit [string index $flags 0]]} {
          lappend xargs $x
          continue
        }
        set pos 0
        foreach flag [split $flags {}] {
          incr pos
          if {[dict exists $flagset $flag]} {
            set d [dict get $flagset $flag]
            apply [dict get $d apply] [dict get $d slot] [dict get $d default]
            continue
          }
          if {[dict exists $optset $flag]} {
            set d [dict get $optset $flag]
            set rest [string range $flags $pos end]
            if {$rest eq {}} {
              if {![llength $opts]} { error "missing value for option -$flag" }
              set rest [lindex $opts 0]
              set opts [lrange $opts 1 end]
            } elseif {[string index $rest 0] eq "="} {
              set rest [string range $rest 1 end]
            }
            apply [dict get $d apply] [dict get $d slot] $rest
            break
          }
          error "unrecognized short flag -$flag"
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
    return $xargs
  }


  proc FindDef {defs tag} {
    foreach d $defs {
      if {$tag eq [dict get $d bare]} { return $d }
    }
    return {}
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
      if {[string match *= $opt]} { set arg 1 }
      string trimright $opt =
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
    set d [Dict $def]
    if {[dict exists $d -default]} { return [dict get $d -default] }
    return 1
  }


  proc Section {def} {
    set d [Dict $def]
    if {[dict exists $d -section]} { return [dict get $d -section] }
    return {}
  }


  proc Info {def} {
    set d [Dict $def]
    if {[dict exists $d -info]} { return [dict get $d -info] }
    return {}
  }


  proc Slot {def} {
    set d [Dict $def]
    if {[dict exists $d -slot]} { return [dict get $d -slot] }
    return {}
  }


  proc Apply {def} {
    set d [Dict $def]
    if {[dict exists $d -apply]} {
      return [list {slot value} [dict get $d -apply]]
    }
    # The default sets a variable in the frame that called ::clip::parse,
    # two levels up from this lambda; wrapping parse in a helper proc
    # redirects the assignment into that wrapper instead
    return {{slot value} { upvar 2 $slot x; set x $value }}
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
        set bare [string trimright [string trimleft $opt -] =]
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


