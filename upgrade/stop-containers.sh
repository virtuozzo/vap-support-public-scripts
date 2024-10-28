#!/bin/bash

NUM_STOP_ONCE=${NUM_STOP_ONCE:-6}
STOP_TIMEOUT=${STOP_TIMEOUT:-60}
FORCE=${FORCE:-0}

[ $FORCE -eq 1 ] || {
	echo 'Please type YES to confirm stopping all the containers: '
	read tmp
	[ x"$tmp" == x'YES' ] || {
		echo 'Confirmation failed'
		exit 1
	}
}

all=( $(vzlist -H1) )

num=0
stop_pipeline=()
stop_pipeline_t=()
stop_pipeline_ct=()
hung_pipeline=()

suggest_cmd() {
	local cmd='stop' tmp
	tmp=$(vzps -E $1 | awk '("mariadbd" == $NF){print $2; exit}')
	[ -z "$tmp" ] || {
		! grep -q wsrep /proc/$tmp/cmdline &>/dev/null || cmd='suspend'
	}
	echo "$cmd"
}

stop() {
	local cmd tmp

	[ -n "$2" ] || {
		return 0
	}

	cmd=$(suggest_cmd $2)

	case cmd in
		suspend)
			tmp='Suspending'
			;;
		*)
			tmp='Stopping'
			;;
	esac

	echo -e "$tmp CTID#\033[32m$2\033[m"
	vzctl $cmd $2 &
	stop_pipeline[$1]=$!
	stop_pipeline_t[$1]=$(date +%s)
	stop_pipeline_ct[$1]=$2

	num=$(( $num + 1 ))
}

check() {
	local pid=${stop_pipeline[$1]}
	[ -n "$pid" ] || return 0

	! kill -s 0 $pid &>/dev/null || {
		[ $(( $2 - $STOP_TIMEOUT )) -ge ${stop_pipeline_t[$1]} ] || return 0

		# Move to hung pipeline
		hung_pipeline+=( $pid )
		hung_pipeline_ct+=( ${stop_pipeline_ct[$1]} )
	}
	num=$(( $num - 1 ))

	stop $1 ${all[$n]}
	n=$(( $n + 1 ))
}

idx=( $(seq 0 1 $(( NUM_STOP_ONCE - 1 ))) )

# Populate stop pipeline
for n in ${idx[*]}
do
	stop $n ${all[$n]}
done

x=${#all[*]}
n=$NUM_STOP_ONCE
[ $n -le $x ] || n=$x

# Wait and populate stop pipeline
while [ $n -lt ${#all[*]} -o $num -gt 0 ]
do
	sleep 5s

	t=$(date +%s)
	for i in ${idx[*]}
	do
		check $i $t
	done
done

# Check hung pipeline
hung=()
for n in ${!hung_pipeline[*]}
do
	! kill -s 0 ${hung_pipeline[$n]} &>/dev/null || {
		hung+=( ${hung_pipeline_ct[$n]} )
	}
done

wait

echo "Done stopping containers"
[ -z "${hung[*]}" ] || {
	echo "Timed out while stopping following containers:"
	vzlist -H ${hung[*]}
}
