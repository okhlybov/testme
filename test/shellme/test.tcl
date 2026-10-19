package require testme

set here [file dirname [info script]]
set root [file normalize $here/../..]
set helpers [file join [file dirname $here] selftest.tcl]

# The sandbox creates a temporary copy of the unit origin and runs commands there
unit -name sandbox-basic [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list data.txt "sample input\n"]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme

unit -name run-sandbox {
  package require shellme
  shellme::sandbox {
    set cat \[expr {\$::tcl_platform(platform) eq \"windows\" ? \"type\" : \"cat\"}\]
    shellme::shell \"\$cat data.txt\"
    shellme::shell {echo newoutput > output.txt}
  }
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl -v -F] code out
    expect clean-exit [expr {$code == 0}]
    expect unit-ok [expr {[matching $out {^ok \d+ - run-sandbox$}] == 1}]
    expect cat-output [expr {[string match {*sample input*} $out]}]
  }
}} $helpers $root]

# The sandbox operates cleanly even when the suite files and directory are read-only
unit -name sandbox-readonly-source [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list readonly.txt "initial content\n"]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme

unit -name run-ro {
  package require shellme
  shellme::sandbox {
    # modify copied file (which would fail if permissions weren't made writable)
    set cat \[expr {\$::tcl_platform(platform) eq \"windows\" ? \"type\" : \"cat\"}\]
    shellme::shell {echo modified >> readonly.txt}
    shellme::shell \"\$cat readonly.txt\"
    # create new file in sandbox
    shellme::shell {echo created > created.txt}
  }
}
"]
  withfixture $pairs {
    # Make fixture files and directory read-only
    if {$::tcl_platform(platform) eq "windows"} {
      file attributes [file join $dir readonly.txt] -readonly 1
      file attributes [file join $dir test.tcl] -readonly 1
      file attributes $dir -readonly 1
    } else {
      file attributes [file join $dir readonly.txt] -permissions 0444
      file attributes [file join $dir test.tcl] -permissions 0444
      file attributes $dir -permissions 0555
    }
    try {
      lassign [capture tclsh $dir/test.tcl -v -F] code out
      expect clean-exit [expr {$code == 0}]
      expect unit-ok [expr {[matching $out {^ok \d+ - run-ro$}] == 1}]
      expect modified [expr {[string match {*modified*} $out]}]
    } finally {
      # restore permissions so fixture cleanup can remove dir
      if {$::tcl_platform(platform) eq "windows"} {
        file attributes $dir -readonly 0
        file attributes [file join $dir readonly.txt] -readonly 0
        file attributes [file join $dir test.tcl] -readonly 0
      } else {
        file attributes $dir -permissions 0755
      }
    }
  }
}} $helpers $root]

# The shell captures stderr on failure and reports errors
unit -name shell-failure [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme

unit -name run-fail {
  package require shellme
  shellme::sandbox {
    shellme::shell {exit 42}
  }
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect failed-exit [expr {$code == 1}]
    expect unit-failed [expr {[matching $out {^not ok \d+ - run-fail$}] == 1}]
  }
}} $helpers $root]

# The watchdog cleans up directories when immediate delete fails
unit -name sandbox-watchdog-cleanup [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
package require shellme

unit -name run-watchdog {
  package require shellme
  if {\$::tcl_platform(platform) ne \"windows\" && !\[catch {exec id -u} uid\] && \[string trim \$uid\] == 0} {
    skip {root deletes read-only directories, the fixture cannot fail}
  }
  set target \[shellme::MakeTempDir\]
  set sub \[file join \$target locked\]
  file mkdir \$sub
  set f \[open \[file join \$sub file.txt\] w]
  puts \$f {temporary}
  close \$f
  # Make subdirectory unreadable/unwritable on Linux, or hold file open on Windows
  if {\$::tcl_platform(platform) eq \"windows\"} {
    set lock \[open \[file join \$sub file.txt\] r\]
  } else {
    file attributes \$sub -permissions 0000
  }

  # Immediate delete fails
  set failed \[catch {file delete -force -- \$target}\]
  if {!\$failed} { error {expected immediate delete to fail} }

  # On Windows, close the lock handle so watchdog retries can clean it up
  if {\$::tcl_platform(platform) eq \"windows\"} {
    close \$lock
  }

  # Spawn watchdog with short timeout
  shellme::SpawnWatchdog \$target 5

  # Poll for up to 3 seconds for watchdog to clean it up
  set deadline \[expr {[clock seconds] + 3}\]
  while {\[file exists \$target\] && \[clock seconds\] < \$deadline} {
    after 100
  }
  if {\[file exists \$target\]} {
    # cleanup on failure
    catch {file attributes \$sub -permissions 0755}
    catch {file delete -force -- \$target}
    error {watchdog failed to clean up target directory}
  }
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect unit-ok [expr {[matching $out {^ok \d+ - run-watchdog( # SKIP.*)?$}] == 1}]
  }
}} $helpers $root]

# The sandbox seeds from the unit origin even when -T staging is active
unit -name sandbox-staged-run [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list data.txt "staged input\n"]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme

unit -name run-staged-sandbox {
  package require shellme
  shellme::sandbox {
    set cat \[expr {\$::tcl_platform(platform) eq \"windows\" ? \"type\" : \"cat\"}\]
    shellme::shell \"\$cat data.txt\"
  }
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl -T -v -F] code out
    expect clean-exit [expr {$code == 0}]
    expect unit-ok [expr {[matching $out {^ok \d+ - run-staged-sandbox$}] == 1}]
    expect cat-output [expr {[string match {*staged input*} $out]}]
  }
}} $helpers $root]

# The shell works when the staging path contains spaces
unit -name shell-spaces-path [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list data.txt "spaced path content\n"]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme

unit -name run-spaced-shell {
  package require shellme
  set cat \[expr {\$::tcl_platform(platform) eq \"windows\" ? \"type\" : \"cat\"}\]
  shellme::shell \"\$cat data.txt\"
}
"]
  set spacedDir [file join [tmproot] "testme spaced path [clock microseconds] [expr {int(rand()*10000)}]-test"]
  file mkdir $spacedDir
  try {
    foreach pair $pairs {
      lassign $pair p content
      set f [open [file join $spacedDir $p] w]
      set h $f
      try { puts $h $content } finally { close $h }
    }
    lassign [capture tclsh $spacedDir/test.tcl -v -F] code out
    expect clean-exit [expr {$code == 0}]
    expect unit-ok [expr {[matching $out {^ok \d+ - run-spaced-shell$}] == 1}]
    expect spaced-output [expr {[string match {*spaced path content*} $out]}]
  } finally {
    file delete -force $spacedDir
  }
}} $helpers $root]

# The shell of the day ($SHELL) is ignored: commands run under /bin/sh
unit -name shell-default-sh [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name run-default-sh {
  package require shellme
  shellme::shell {echo shell-ok}
}
"]
  withfixture $pairs {
    set old_shell [expr {[info exists ::env(SHELL)] ? $::env(SHELL) : ""}]
    set had_shell [info exists ::env(SHELL)]
    set ::env(SHELL) /bin/false
    try {
      lassign [capture tclsh $dir/test.tcl -v -F] code out
    } finally {
      if {$had_shell} {
        set ::env(SHELL) $old_shell
      } else {
        unset ::env(SHELL)
      }
    }
    expect clean-exit [expr {$code == 0}]
    expect unit-ok [expr {[matching $out {^ok \d+ - run-default-sh$}] == 1}]
    expect shell-ran [expr {[string match {*shell-ok*} $out]}]
  }
}} $helpers $root]

# SHELLME_SHELL overrides the default shell
unit -name shell-override [list apply {{helpers root} {
  source $helpers
  if {[auto_execok bash] eq {}} {
    skip {bash is unavailable}
  }
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name run-bash {
  package require shellme
  shellme::shell {echo bash=\$\{BASH_VERSION:-none\}}
}
"]
  withfixture $pairs {
    set old_shell [expr {[info exists ::env(SHELLME_SHELL)] ? $::env(SHELLME_SHELL) : ""}]
    set had_shell [info exists ::env(SHELLME_SHELL)]
    set ::env(SHELLME_SHELL) bash
    try {
      lassign [capture tclsh $dir/test.tcl -v -F] code out
    } finally {
      if {$had_shell} {
        set ::env(SHELLME_SHELL) $old_shell
      } else {
        unset ::env(SHELLME_SHELL)
      }
    }
    expect clean-exit [expr {$code == 0}]
    expect bash-ran [expr {[string match {*bash=*[0-9]*} $out] && ![string match {*bash=none*} $out]}]
  }
}} $helpers $root]

# Hostile characters in the staging path survive the shell quoting
unit -name shell-quote-hostile [list apply {{helpers root} {
  source $helpers
  set hostile [file join [tmproot] "hostile \$dollar 'quote' [clock microseconds]-test"]
  file mkdir $hostile
  try {
    set f [open [file join $hostile test.tcl] w]
    puts $f "tcl::tm::add $root
package require testme
unit -name hostile-path {
  package require shellme
  if {\$::tcl_platform(platform) eq \"windows\"} {
    shellme::shell {cd}
  } else {
    shellme::shell {pwd}
  }
  shellme::shell {echo survived}
}
"
    close $f
    lassign [capture tclsh [file join $hostile test.tcl] -v -F] code out
    expect clean-exit [expr {$code == 0}]
    expect unit-ok [expr {[matching $out {^ok \d+ - hostile-path$}] == 1}]
    expect survived [expr {[string match {*survived*} $out]}]
  } finally {
    file delete -force $hostile
  }
}} $helpers $root]

# -timeout aborts a stuck command and kills its whole process tree
unit -name shell-timeout [list apply {{helpers root} {
  source $helpers
  if {$::tcl_platform(platform) eq "windows"} {
    skip {POSIX process groups needed}
  }
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
unit -name stuck {
  package require shellme
  shellme::shell -timeout 1 {sleep 987654 & sleep 987655}
}
"]
  withfixture $pairs {
    set t0 [clock milliseconds]
    lassign [capture tclsh $dir/test.tcl] code out
    set dt [expr {[clock milliseconds] - $t0}]
    expect failed [expr {$code == 1}]
    expect unit-failed [expr {[matching $out {^not ok \d+ - stuck$}] == 1}]
    expect timed-out [expr {[matching $out {command timed out after 1 s}] == 1}]
    expect prompt [expr {$dt < 8000}]
    # the whole tree must be gone
    set gone 0
    for {set i 0} {$i < 20} {incr i} {
      if {[catch {exec pgrep -f 98765}]} {
        set gone 1
        break
      }
      after 200
    }
    expect tree-killed [expr {$gone == 1}]
  }
}} $helpers $root]

# A unit time limit reaps the children of a shell stuck in a read
unit -name shell-unit-timeout-kills [list apply {{helpers root} {
  source $helpers
  if {$::tcl_platform(platform) eq "windows"} {
    skip {POSIX process groups needed}
  }
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
package require shellme
shellme::unit -name stuck -timeout 1 {
  shellme::shell {sleep 987656}
}
unit -name witness {
  after 3000
  if {![catch {exec pgrep -f 987656} found]} {
    error \"leftover processes: \$found\"
  }
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect failed [expr {$code == 1}]
    expect timed-out [expr {[matching $out {^not ok \d+ - stuck$}] == 1 && [matching $out {timed out after 1 s}] == 1}]
    expect children-reaped [expr {[matching $out {^ok \d+ - witness$}] == 1}]
  }
}} $helpers $root]

# shellme::unit submits a fully configured unit: seeded staging, shell, capture
unit -name shellme-unit-basic [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list data.txt "seed content\n"]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
package require shellme

shellme::unit -name build-it -tags {build} {
  # the staging space is preconfigured: the shell works right away
  set cat \[expr {\$::tcl_platform(platform) eq \"windows\" ? \"type\" : \"cat\"}\]
  shellme::shell \"\$cat data.txt\"
  # and the sandbox is writable immediately
  set f \[open \[file join \[shellme::stage\] made.txt\] w\]
  puts \$f made
  close \$f
  if {!\[file exists \[file join \[shellme::stage\] data.txt\]\]} {
    error {the sandbox was not seeded from the origin}
  }
}
unit -name plain {expr {1}}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl -v -F] code out
    expect clean-exit [expr {$code == 0}]
    expect unit-ok [expr {[matching $out {^ok \d+ - build-it$}] == 1}]
    expect seeded [expr {[string match {*seed content*} $out]}]
    expect origin-clean [expr {![file exists [file join $dir made.txt]]}]
    expect plain-ok [expr {[matching $out {^ok \d+ - plain$}] == 1}]
  }
}} $helpers $root]

# Program I/O redirected onto the process streams is captured in shellme units
unit -name shellme-unit-exec-capture [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
package require shellme

shellme::unit -name redirects {
  exec \[info nameofexecutable\] << {puts EXECOUT-CAPTURED} >@ stdout
  exec \[info nameofexecutable\] << {puts stderr EXECERR-CAPTURED} 2>@ stderr
}
"]
  withfixture $pairs {
    # plain run: the TAP stream carries none of the program output
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect stream-clean [expr {[matching $out {EXECOUT-CAPTURED|EXECERR-CAPTURED}] == 0}]
    expect unit-ok [expr {[matching $out {^ok 1 - redirects$}] == 1}]
    # verbose run: the dump carries all of it
    lassign [capture tclsh $dir/test.tcl -v -F] code2 out2
    expect stdout-captured [expr {[matching $out2 {EXECOUT-CAPTURED}] >= 1}]
    expect stderr-captured [expr {[matching $out2 {EXECERR-CAPTURED}] >= 1}]
  }
}} $helpers $root]

# Seeding control: -exclude filters top-level names, -only picks paths
unit -name shellme-unit-seeding [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list src/a.c "int main(){}\n"]
  lappend pairs [list Makefile "all:\n"]
  lappend pairs [list {sub/deep.txt} "deep\n"]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
package require shellme

shellme::unit -name picky -only {src/a.c sub/deep.txt} {
  if {!\[file exists \[file join \[shellme::stage\] src a.c\]\]} {error {src/a.c missing}}
  if {!\[file exists \[file join \[shellme::stage\] sub deep.txt\]\]} {error {sub/deep.txt missing}}
  if {\[file exists \[file join \[shellme::stage\] Makefile\]\]} {error {Makefile should not be copied}}
}
shellme::unit -name excluded -exclude {Makefile src} {
  if {\[file exists \[file join \[shellme::stage\] Makefile\]\]} {error {Makefile should be excluded}}
  if {\[file exists \[file join \[shellme::stage\] src\]\]} {error {src should be excluded}}
  if {!\[file exists \[file join \[shellme::stage\] sub\]\]} {error {sub should be copied}}
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect picky-ok [expr {[matching $out {^ok \d+ - picky$}] == 1}]
    expect excluded-ok [expr {[matching $out {^ok \d+ - excluded$}] == 1}]
  }
}} $helpers $root]

# A timed out shellme unit leaves neither processes nor sandboxes behind
unit -name shellme-unit-timeout-cleanup [list apply {{helpers root} {
  source $helpers
  if {$::tcl_platform(platform) eq "windows"} {
    skip {POSIX process groups needed}
  }
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
package require shellme

shellme::unit -name stuck -timeout 1 {
  shellme::shell {sleep 987657}
}
unit -name witness {
  after 3000
  if {![catch {exec pgrep -f {sleep 987657}} found]} {
    error \"leftover processes: \$found\"
  }
  foreach d \[glob -nocomplain -directory \[tmproot\] test.tcl-* test-* shellme* *.tcl-*\] {
    error \"leftover staging: \$d\"
  }
}
"]  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect failed [expr {$code == 1}]
    expect timed-out [expr {[matching $out {^not ok \d+ - stuck$}] == 1}]
    expect children-reaped [expr {[matching $out {^ok \d+ - witness$}] == 1}]
  }
}} $helpers $root]

# -staging none skips the sandbox but keeps the program I/O capture
unit -name shellme-unit-staging-none [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
package require shellme

shellme::unit -name bare -staging none {
  if {\[shellme::stage\] eq {}} {error {stage should fall back to the unit record}}
  exec \[info nameofexecutable\] << {puts BARE-CAPTURED} >@ stdout
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect unit-ok [expr {[matching $out {^ok 1 - bare$}] == 1}]
    expect stream-clean [expr {[matching $out {BARE-CAPTURED}] == 0}]
    lassign [capture tclsh $dir/test.tcl -v -F] code2 out2
    expect captured [expr {[matching $out2 {BARE-CAPTURED}] >= 1}]
  }
}} $helpers $root]

# shellme version matches testme's version (0.1.0)
unit -name shellme-version [list apply {{helpers root} {
  source $helpers
  set pairs [list]
  lappend pairs [list test.tcl "tcl::tm::add $root
package require testme
package require shellme 0.1.0

unit -name check-version {
  package require shellme 0.1.0
  if {\[package present shellme\] ne {0.1.0}} {
    error \"unexpected shellme version: \[package present shellme\]\"
  }
}
"]
  withfixture $pairs {
    lassign [capture tclsh $dir/test.tcl] code out
    expect clean-exit [expr {$code == 0}]
    expect unit-ok [expr {[matching $out {^ok 1 - check-version$}] == 1}]
  }
}} $helpers $root]
