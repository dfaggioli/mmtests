#!/bin/bash

install-depends perf

while [ 1 ]; do
	echo time: `date +%s`
	exec perf top --stdio -d $MONITOR_UPDATE_FREQUENCY | perl -e 'while (<>) {
		if ($_ =~ /PerfTop:/) {
			print "time: " . time . "\n";
		}
		print $_;}'
done
