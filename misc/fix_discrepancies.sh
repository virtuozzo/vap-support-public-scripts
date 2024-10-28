#!/bin/bash

NETDEVICES=( $(
	. /etc/sysconfig/vz-scripts/vz-functions &>/dev/null || \
	. /usr/libexec/libvzctl/scripts/vz-functions &>/dev/null || :
	vzgetnetdev
	echo "$NETDEVICES")
)

error() {
	echo -e "\033[31mERROR${@:+:}\033[m${@:+ $@}" >&2
}

fail() {
	error "$@"
	exit 1
}

VERSION_ID=$(. /etc/os-release &>/dev/null; echo "$VERSION_ID")
[ -n "$VERSION_ID" ] || fail 'Unable to determine OS distribution version'

SRC_DEV=$(. /etc/vz/vz.conf; echo "$VE_ROUTE_SRC_DEV")
[ -n "$SRC_DEV" ] || fail 'Unable to identify route source device'

SRC_IP=$(ip a s "$SRC_DEV" | \
	awk '("inet" == $1){print gensub(/[/].+$/, "", "", $2); exit}')
[ -n "$SRC_IP" ] || fail "Unable to identify route source ip for the $SRC_DEV device"

FIX=0
[ x"$1" != x'fix' ] || FIX=1

# expand_ipv6() - expand ipv6 representation to its full 39-character notation
# @stdin - stream with ipv4 and ipv6 addresses
function expand_ipv6() {
	[ x"$VERSION_ID" != x6 ] || {
		grep -v ':'
		return
	}

	awk '
	/:/{
		# Expand :: empty group
		n = 8 - split($1, ip, ":") + 1
		if (1 < n) {
			tmp = ""
			for(; n >= 1; n--) {tmp="0000:"tmp}
			sub(/::/, ":"tmp, $1)
		}

		# Expand hextets
		split($1, ip, ":")
		$1 = ""
		for(i = 1; i <= 8; i++) {
			tmp = ""
			for(n = 4 - length(ip[i]); n; n--) {
				tmp = "0"tmp
			}
			$1 = $1":"tmp""ip[i]
		}
		$1 = substr($1, 2)
	}
	{ print }'
}

active_ips() {
        vmtype=$1
        if [[ "$vmtype" == "CT" || -z $vmtype ]]; then
                [ ${#IPS_CTS} -gt 1 ] && {
                cat << EOF
$IPS_CTS
EOF
}
        fi
        if [[ "$vmtype" == "VM" || -z $vmtype ]]; then
                [ ${#IPS_VMS} -gt 1 ] || return
                cat << EOF
$IPS_VMS
EOF
        fi

}

proc_ips() {
	awk '{for(tmp = 4; tmp <= NF; tmp++){print $tmp}}' /proc/vz/veinfo | \
		expand_ipv6 | \
		sort -u
}

route_ips() {
	{
		ip r s t main
		ip -6 r s t main
	} | \
		awk '{
			tmp["dev"] = ""
			for(i = 1; i <= NF; i++) {
				tmp[$i] = $(i + 1)
			}
		if ("venet0" == tmp["dev"] && "fe80::1" != $1) print $1
		}' | \
		expand_ipv6 | \
		sort
}

route_ips_vms() {
	{
		ip r s t main
		ip -6 r s t main
	} | \
		ip r | awk '{
			tmp["dev"] = ""
			for(i = 1; i <= NF; i++) {
				tmp[$i] = $(i + 1)
			}
		if (tmp["dev"] ~ /^vme/ && "fe80::1" != $1 && "169.254.0.0/16" != $1) print $1
		}' | \
		expand_ipv6 | \
		sort
}

# dump_arp_ips() - Dump static ARP entries with iproute
dump_arp_ips() {
	ip neigh show proxy | \
		awk "
		BEGIN {
			$1
		}
		{
			if (\"proxy\" == \$NF) {
				tmp[\"dev\"] = \"\"
				for(i = 1; i <= NF; i++) {
					tmp[\$i] = \$(i + 1)
				}
				d = tmp[\"dev\"]
				if (nic[d]) print \$1\" \"d
			}
		}"
}

# dump_arp_ips6() - Dump static ARP entries with legacy arp tool
dump_arp_ips6() {
	arp -na | \
		awk "
		BEGIN {
			$1
		}
		{
			tmp[\"on\"] = \"\"
			tmp[\"PERM\"] = \"\"
			for(i = 1; i < NF; i++) {
				tmp[\$i] = \$(i+1)
			}
			d = tmp[\"on\"]
			if (tmp[\"PERM\"] == \"PUP\" && nic[d] == tmp[\"on\"]) {
				print gensub(/^[(]|[)]\$/, \"\", \"g\", \$2)\" \"d
			}
		}"
}

arp_ips() {
	local tmp arg dump

	for tmp in ${NETDEVICES[*]}
	do
		arg="${arg:+$arg$'\n'}nic[\"$tmp\"]=\"$tmp\""
	done

	dump='dump_arp_ips'
	[ x"$VERSION_ID" != x6 ] || dump="${dump}6"

	$dump "$arg" | \
		expand_ipv6 | \
		sort
}

nic_active_ips() {
	local tmp

	for tmp in ${NETDEVICES[*]}
	do
		active_ips | sed -r "s/\$/ $tmp/"
	done | sort
}

diff_single() {
	diff -up $1 $2 | sed -nr \
		-e '4,${s/^[-+]/& /p}'
}

fix_proc() {
	error "Floating IP address $3 is in use and can not be fixed automatically"
}

fix_route() {
	local tmp v='-6'

	[ $1 -eq 6 ] || {
		tmp="src $SRC_IP"
		v=
	}

	[ x"$2" == x'-' ] || {
		ip $v r d t main "$3"
		return 0
	}

	ip $v r a t main "$3" dev venet0 $tmp
}

fix_route_vm() {
	local tmp v='-6'

	[ $1 -eq 6 ] || {
		tmp="src $SRC_IP"
		v=
	}

	[ x"$2" == x'-' ] || {
		ip $v r d t main "$3"
		return 0
	}
	
	error "Currently missed route can not be added for VMs"
}

fix_arp() {
	local v='-6'

	[ $1 -eq 6 ] || v=

	[ x"$2" == x'-' ] || {
		ip $v neigh del proxy "$3" dev "$4"
		return 0
	}

	ip $v neigh add proxy "$3" dev "$4"
}

check_single() {
	local tmp msg err=0 v

	exec 3< <(diff_single $2 $3)
	while read -u 3 -a tmp
	do
		case $tmp in
		'+')
			msg="Unexpected"
		;;
		'-')
			msg="Missing"
		;;
		*)
			continue
		;;
		esac

		v=4
		[ -n "${tmp[1]##*:*}" ] || v=6

		err=1

		msg="$msg ${tmp[1]} $1"
		[ ${#tmp[*]} -eq 2 ] || msg="$msg for ${tmp[2]}"
		echo -e "\033[33;1m$msg\033[m"

		[ $FIX -ne 1 ] || fix_${1%% *} "$v" ${tmp[*]}
	done
	exec 3>&-

	return $err
}

function dump_active_ips() {
	local tmp=( $(vzlist -Ho private) )

	for tmp in ${tmp[*]}
	do
		. $tmp/ve.conf &>/dev/null || continue
		echo "$IP_ADDRESS"
	done
}

function dump_active_ipv4_ips(){
	dump_active_ips | \
		sed -r 's/[[:blank:]]+/\n/g' | \
		sed -nr '/^[[:blank:]]*$/!{/^0[.]0[.]0[.]0$/!{s/[/][^/]+$//; p}}' | \
		expand_ipv6 | \
		sort -u
}

dump_active_ips_vms_expanded(){
   prlctl list --vmtype vm -H -i -j | \
      jq -r ".[] | select(.State == \"running\" ) | .Hardware | \
        (select(.net0 != null)| .net0), (select(.net1 != null)| .net1), (select(.net2 != null)| .net2) | \
        select (.type == \"routed\" ) | select (.ips != null ) | .ips" |\
      sed -r 's/[[:blank:]]+/\n/g' | \
      sed -nr '/^[[:blank:]]*$/!{/^0[.]0[.]0[.]0$/!{s/[/][^/]+$//; p}}' | \
      expand_ipv6 | \
      sort -u
}

check() {
	local err=0

	NETDEVICES=( ${NETDEVICES[*]//docker0/} )

	IPS_CTS="$(dump_active_ipv4_ips)"

	IPS_VMS="$(dump_active_ips_vms_expanded)"


	# Match with proc
	check_single 'proc record' <(active_ips CT) <(proc_ips) || err=$?

	# Match with routes
	check_single 'route' <(active_ips CT) <(route_ips) || err=$?

  # Match with routes
	check_single 'route_vm' <(active_ips VM) <(route_ips_vms) || err=$?

	# Match with arp
	check_single 'arp entry' <(nic_active_ips) <(arp_ips) || err=$?

	return $err
}

! check $1 || \
	echo 'No discrepancies were found'
