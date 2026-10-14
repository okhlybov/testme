package require testme

# The expected shape: a parametrization cycle submitting the whole series at once
foreach x {p q r} {
  unit -name "param-$x" -tags {slow} [list string toupper $x]
}

puts b
