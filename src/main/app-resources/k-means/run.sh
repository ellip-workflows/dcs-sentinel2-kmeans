#!/bin/bash

# source the ciop functions (e.g. ciop-log, ciop-getparam)
source ${ciop_job_include}

source /application/k-means/lib/functions.sh

trap cleanExit EXIT

while read input
do
  main ${input} || exit $?
done
