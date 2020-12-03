FINEGRAINED_SUPPORTED=yes
NAMEEXTRA=

$SHELLPACK_TOPLEVEL/shellpack_src/src/refresh.sh custom-bench

run_bench() {
	$SCRIPTDIR/shellpacks/shellpack-bench-custom-bench \
		--name		$CUSTOM_BENCH_NAME \
		--iterations	$CUSTOM_BENCH_ITERATIONS \
		--cmd		"$CUSTOM_BENCH_CMD"
	return $?
}
