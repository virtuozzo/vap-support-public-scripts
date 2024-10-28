#!/bin/bash

RUN_MODE=0;

function warnmsg(){
echo -e "\\033[1;33m$@\\033[0;39m";
}

function infomsg(){
echo -e "\\033[1;32m$@\\033[0;39m";
}

function failmsg(){
echo -e "\\033[1;31m$@\\033[0;39m";
}

function epicfail(){
echo -e "\\033[1;31m$@\\033[0;39m";
exit 255;
}

function boldmsg(){
echo -e "\\033[1;37m$@\\033[0;39m";
}

function greymsg(){
echo -e "\\033[1;30m$@\\033[0;39m";
}

function epicwin(){
        echo -e "\\033[1;32m$@\\033[0;39m";
        exit 0;
}
echo -e "======================================================";
boldmsg "             Platform post outage checker";
echo -e "======================================================";
infomsg "Hostname: [ $(hostname 2>/dev/null) ]";
warnmsg "Uptime info: [$(uptime) ]";
echo -e;

function pgrep_s(){
timeout 60 vzctl exec2 $tmp "pgrep $1" &>/dev/null && infomsg "CT $tmp: $1 - [OK]" || { failmsg "CT $tmp: $1 - [FAIL];"; return 255; } ;
}

function systemctl_service(){
timeout 60 vzctl exec2 $tmp "systemctl status $1" &>/dev/null && infomsg "CT $tmp: $1 - [OK]" || { failmsg "CT $tmp: $1 - [FAIL]"; return 255; } ;
}

function f_check_vz_writable(){
echo -e;
rm -f /vz/private/write.test.file;
timeout 30 touch /vz/private/write.test.file;
[ ! -f "/vz/private/write.test.file" ] && epicfail "/vz/private isn't writable!" || infomsg "/vz/private is writable!";
rm -f /vz/private/write.test.file;
echo -e;
}

version_detect(){
	INFRA_CT_ID=$1;
	VAP_VERSION_MAJOR=$(vzctl exec2 $INFRA_CT_ID "cat /etc/jelastic/jinfo.ini"  | awk -F ':' {'print $1'} | awk -F '-' {'print $1'} | awk -F '.' {'print $1'} | head -n 1);
	VAP_VERSION_MINOR=$(vzctl exec2 $INFRA_CT_ID "cat /etc/jelastic/jinfo.ini"  | awk -F ':' {'print $1'} | awk -F '-' {'print $1'} | awk -F '.' {'print $2'} | head -n 1);
	TOTAL_VERSION=$(echo "$VAP_VERSION_MAJOR$VAP_VERSION_MINOR");
	[ $TOTAL_VERSION -ge 63 ] && return 0 || return 255;
}

function f_check_java_response(){
   [ $1 == 'jelcore' ] && { timeout 60 vzctl exec2 $tmp 'echo $(timeout 45 curl -q "http://$(hostname):8080/JElastic/env/system/rest/getversion?appid=1dd8d191d38fff45e62564fcf67fdcd6")' 2>/dev/null || return 255; }
     [ $1 == 'hcore' ] && { timeout 60 vzctl exec2 $tmp 'echo $(timeout 45 curl -q "http://127.0.0.1:8080/users/system/service/rest/getversion?appid=cluster")' 2>/dev/null || return 255; }

     [ $1 == 'jpool' ] && { timeout 60 vzctl exec2 $tmp 'echo $(timeout 45 curl -q "http://$(hostname):8080/JPoolManager/pool/system/rest/getversion?appid=1dd8d191d38fff45e62564fcf67fdcd6")' 2>/dev/null || return 255; }
  [ $1 == 'jbilling' ] && { timeout 60 vzctl exec2 $tmp 'echo $(timeout 45 curl -q "http://$(hostname):8080/JBilling/billing/system/rest/getversion?appid=1dd8d191d38fff45e62564fcf67fdcd6")' 2>/dev/null || return 255; }
[ $1 == 'jstatistic' ] && { timeout 60 vzctl exec2 $tmp 'echo $(timeout 45 curl -q "http://$(hostname):8080/JStatistic/statistic/system/rest/getversion?appid=1dd8d191d38fff45e62564fcf67fdcd6")' 2>/dev/null || return 255; }
return 0;
}

function f_check_platform_services(){
local INFRA_CONTAINERS="zookeeper jelastic-db jrouter jelcore jpool jbilling jstatistic memcached-infra hcore awakener uploader resolver zabbix webgate msa backuper gate db-backup auth kafka";
vzlist -Ho ctid,hostname 2>/dev/null > /tmp/infra.vzlist.tmp
for ICTN in $INFRA_CONTAINERS;
	do
#	greymsg "Checking $ICTN:";
	INFRA_RUNNING_AMOUNT=$( grep -E "$ICTN\.|$ICTN[[:digit:]]+\." /tmp/infra.vzlist.tmp | wc -l);
	INFRA_ALL_AMOUNT=$( grep -E "$ICTN\.|$ICTN[[:digit:]]+\." /tmp/infra.vzlist.tmp | wc -l);
	[ $INFRA_RUNNING_AMOUNT -eq 0 -a ! $INFRA_ALL_AMOUNT -eq 0 ] && failmsg "No running $ICTN, but stopped found!" && continue;
	[ $INFRA_ALL_AMOUNT -eq 0 ] && greymsg "No $ICTN found, skipping..." && continue;
	INFRA_CTIDS=$(vzlist -Ho ctid,hostname | grep -E "[[:blank:]]$ICTN\.|[[:blank:]]$ICTN[[:digit:]]+\." | awk {'print $1'});
	for tmp in $INFRA_CTIDS;
	do
                CTUPTIME=$(vzctl exec2 $tmp uptime -ps 2>/dev/null);
               	boldmsg "Checking $ICTN: (Uptime: $CTUPTIME):";

	case $ICTN in
     		zookeeper) pgrep_s java; ;;
		db-backup) systemctl_service mysql; ;;
     		jelastic-db) version_detect $tmp && { pgrep_s mariadbd; systemctl_service jelasticha; systemctl_service corosync; } || pgrep_s mysql; ;;
     		jrouter)  pgrep_s nginx; ;; 
     		gate) version_detect $tmp && systemctl_service corosync; pgrep_s sshproxyd; pgrep_s sshd; ;;
		jelcore|jbilling|jstatistic|jpool) pgrep_s java && { f_check_java_response $ICTN || failmsg "CT $tmp: No API response from $ICTN"; }; ;;
     		resolver) for r_services in mysql openresty pdns-recursor pdns pdns@external postfix haresolver proxysql dnsdist; do systemctl_service $r_services; done ;;
		memcached-infra) pgrep_s memcached; ;;
		hcore)  version_detect $tmp && { pgrep_s nginx; systemctl_service proxysql; } ;  pgrep_s java && { f_check_java_response $ICTN || failmsg "CT $tmp: No API response from $ICTN"; };
		          vzctl exec2 $tmp "timeout 15 ls -l /home/hivext/ftp &>/dev/null" && infomsg "CT $tmp: Mount to /home/hivext/ftp - [OK]" || failmsg "Mount to /home/hivext/ftp - [FAIL]"; ;;
		uploader) pgrep_s java; ;;
		awakener) pgrep_s java; ;;
		zabbix)   vzctl exec2 $tmp "netstat -ntlp | grep 10051 | grep -q zabbix_server" && infomsg "CT $tmp: Zabbix-server - [OK]" || failmsg "CT $tmp: Zabbix-server - [FAIL]";
			  pgrep_s nginx; pgrep_s mysql; pgrep_s php-fpm; ;;
		webgate)  pgrep_s java; pgrep_s guacd; ;;
		msa)      pgrep_s msa-handler; systemctl_service postfix; ;;
		auth)	systemctl_service keycloak; ;;
		kafka) systemctl_service kafka; ;;
		
	esac
	vzctl exec2 $tmp "netstat -ntlp | grep 10050 | grep -q zabbix" && infomsg "CT $tmp: Zabbix-agent - [OK]" || failmsg "CT $tmp: Zabbix-agent - [FAIL]"; 
	done	
done
return 0;	
}

f_check_vz_writable;
f_check_platform_services;
