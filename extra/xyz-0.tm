# This package provides multiple library build flavors (for MSYS2) differentiated by
# the 3-character suffix XYZ as follows:
#
#  * X is the scalar type based on the Netlib's SDCZ notation:
#    - A for multiprecision or precision-neutral build
#    - S for single precision real
#    - D for double precision real
#    - C for single precision complex
#    - Z for double precision complex
#
#  * Y is the execution model:
#    - S for sequential code
#    - M for MPI parallel code
#    - T for multithreaded code, either bare threading or OpenMP, OpenACC etc.
#    - H for heterogeneous code with CUDA, OpenCL etc.
#
#  * Z is the build type:
#    - O for optimized build
#    - G for debugging build
#
# The suffix is used in the static and dynamic libraires as well as in PkgConfig .pc files.
# That is the ZMO suffix designates the optimized MPI parallel double precision complex library flavor.
# Consider the `pkgconf ${package}-zmo --cflags` command to obtain the build-specific compilation flags for ${package}.


package require testme

namespace eval ::xyz {
  proc unit {prefix tags args} {
    set code [lindex $args end]
    set rest [lrange $args 0 end-1]
    set opts [dict merge $rest [dict create \
      -tags $tags \
      -name [DescribeXYZ $prefix $tags] \
      -xyz [DeduceXYZ $tags] \
      -static [DeduceStatic $tags] \
    ]]
    if {[llength [info commands ::testme::submit]] > 0} {
      ::testme::submit $opts $code
    } else {
      testme::unit -name [dict get $opts -name] -tags $tags $code
    }
  }

  proc any? {tag tags} {
    foreach t $tag {
      if {[lsearch -exact $tags $t] >= 0} {return 1}
    }
    return 0
  }

  proc DeduceXYZ {tags} {
    if {[any? debug $tags]} {set z g} else {set z o}
    if {[any? mpi $tags]} {
      set y m
    } elseif {[any? {omp openmp thread threads} $tags]} {
      set y t
    } elseif {[any? {hetero cuda opencl hip} $tags]} {
      set y h
    } else {
      set y s
    }
    if {[any? {any multiprecision neutral} $tags]} {
      set x a
    } elseif {[any? complex $tags]} {
      if {[any? single $tags]} {set x c} else {set x z}
    } else {
      if {[any? single $tags]} {set x s} else {set x d}
    }
    return $x$y$z
  }

  proc DescribeXYZ {prefix tags} {
    set prefix "$prefix:"
    if {[any? {any multiprecision neutral} $tags]} {set prefix "$prefix multiprecision"}
    if {[any? single $tags]} {set prefix "$prefix single-precision"}
    if {[any? double $tags]} {set prefix "$prefix double-precision"}
    if {[any? complex $tags]} {set prefix "$prefix complex"}
    if {[any? mpi $tags]} {
      set prefix "$prefix MPI"
    } elseif {[any? {omp openmp thread threads} $tags]} {
      set prefix "$prefix OpenMP"
    } elseif {[any? {hetero cuda opencl hip} $tags]} {
      set prefix "$prefix heterogeneous"
    }
    if {[any? debug $tags]} {set prefix "$prefix debug"}
    if {[any? c $tags]} {set prefix "$prefix C"}
    if {[any? {cxx c++ cpp} $tags]} {set prefix "$prefix C++"}
    if {[any? fortran $tags]} {set prefix "$prefix FORTRAN"}
    if {[any? static $tags]} {set prefix "$prefix static"}
    set prefix "$prefix build"
    return $prefix
  }

  proc DeduceStatic {tags} {
    if {[any? static $tags]} {return {-static}} else {return {}}
  }
}