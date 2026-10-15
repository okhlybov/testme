# Self test helpers: the unit codes source this file inside their clean interpreters


# True when running as root on a POSIX system: root can delete read-only
# trees, which defeats the permission-based failure fixtures
proc isroot {} {
  expr {$::tcl_platform(platform) ne "windows"
        && ![catch {exec id -u} uid] && [string trim $uid] == 0}
}


# A writable scratch root: the platform temp directory before the /tmp fallback
proc tmproot {} {
  foreach var {TMPDIR TEMP TMP} {
    if {[info exists ::env($var)] && [file isdirectory $::env($var)]} {
      return $::env($var)
    }
  }
  return /tmp
}


# Runs a command capturing the exit status together with the merged output
proc capture {args} {
  if {[catch {exec {*}$args 2>@1} out]} {
    return [list 1 $out]
  }
  return [list 0 $out]
}


# Fails the unit unless the condition holds
proc expect {label ok} {
  if {!$ok} {error "selftest: $label"}
}


# Counts the output lines matching the regular expression
proc matching {out pattern} {
  llength [lsearch -all -regexp [split $out \n] $pattern]
}


# Creates a scratch suite tree from the {path content} pairs, evaluates
# the body with the tree root in $dir, removes the tree afterwards
proc withfixture {pairs body} {
  upvar 1 dir dir
  # The name must not collide across the worker threads (pid is process wide)
  set dir [file join [tmproot] testme-selftest-[pid]-[clock microseconds]-[expr {int(rand()*1000000)}]]
  file mkdir $dir
  foreach pair $pairs {
    lassign $pair path content
    set f [file join $dir {*}$path]
    file mkdir [file dirname $f]
    set h [open $f w]
    try { puts $h $content } finally { close $h }
  }
  try {
    uplevel 1 $body
  } finally {
    file delete -force $dir
  }
}
