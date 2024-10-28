#!/bin/bash

#
# Script Guide for Restoration from Backup
# operations/-/blob/master/automation-scripts/ct_replace_vz7_new.sh
#

fail() {
   echo -e; 
   echo -e "\033[1;31mERROR: $@\033[m"
   echo -e;
   exit 1
}
TMPCTNAME=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1);

errmsg() {
   echo -e;
   echo -e "\033[1;31mERROR: $@\033[m";
   echo -e;
}

okmsg() {
   echo -e;
   echo -e "\033[1;32m$@\033[m";
   echo -e;
}

infomsg() {
   echo -e;
   echo -e "\033[1;37m$@\033[m";
   echo -e;
}

border() {
   echo -e "\033[1;37m==============================================================================================================\033[m";
}


sleep 1

f_checkcomputetype() {
   
   infomsg "Determining the compute types of containers..."
        infomsg "Mounting containers..."
   
   vzctl --quiet mount $1;
   vzctl --quiet mount $2;
   
   srcnodetype="/vz/root/$1/etc/jelastic/metainf.conf"
        srcnodetype=$(sed -nr '/^[[:blank:]]*COMPUTE_TYPE=["'\'']?([^"'\'']+)["'\'']?[[:blank:]]*$/{s//\1/p; q}' "$srcnodetype");
        destnodetype="/vz/root/$2/etc/jelastic/metainf.conf"
        destnodetype=$(sed -nr '/^[[:blank:]]*COMPUTE_TYPE=["'\'']?([^"'\'']+)["'\'']?[[:blank:]]*$/{s//\1/p; q}' "$destnodetype");

        infomsg "Source container $i compute type: $srcnodetype";
        infomsg "destination container $i compute type: $destnodetype";

        if [[ "$srcnodetype" == "$destnodetype" ]]; 
        then 
        {
        okmsg "The compute types of the containers are identical...continue...";
   
   vzctl --quiet umount $1;
   vzctl --quiet umount $2; }
       
   else
        {
        errmsg "The compute types are different! Aborting...";
        sleep 1;
        infomsg "Unmounting containers...."
        vzctl --quiet umount $1;
        vzctl --quiet umount $2;
        exit 1; }
        fi

}

f_fixhostnames() {
   local srcctname=$(vzlist -Ho name $1);
   local srchostname=$(vzlist -Ho hostname $1);
   local destctname=$(vzlist -Ho name $2);
   local desthostname=$(vzlist -Ho hostname $2);
   local moddestctname=$(echo $srcctname | sed 's/$1/$2/');
   vzctl --quiet set $2 --name "$TMPCTNAME" --save;
   vzctl --quiet set $1 --hostname "$desthostname" --name "$destctname" --save;
   okmsg "The names and hostnames now are the same for both containers!";
   validate "$1" "$2";
}

confirmfix() {
   errmsg "Containers $src and $dest are not compatible due to different hostnames";
   infomsg "Would you like to fix the issue? (Make sure that the CTIDs of restored and destnation containers are correct!) (Y/n)";
   read response;
   case "$response" in
        [yY][eE][sS]|[yY])     
   f_fixhostnames "$1" "$2";
            ;;
        *)
        exit 1
            ;;
    esac
}

check() { 
   vzlist $2 &>/dev/null || fail "$1 container $2 not found" 
}

validate() {
   okmsg "Validating the containers..."
   local src=$(vzlist -Ho hostname $1) dest=$(vzlist -Ho hostname $2)
   local ctidsrc=$(vzlist -Ho ctid $1) ctiddest=$(vzlist -Ho ctid $2)
   sleep 1
   border;
   echo -e "\033[1;37m     Source container:\033[m\033[1;33m $ctidsrc \033[m\033[1;32m$src\033[m";
   echo -e "\033[1;37mDestination container:\033[m\033[1;33m $ctiddest \033[m\033[1;32m$dest\033[m";
   border;
   sleep 1
        [ "$(vzlist $1 -Ho status)" == stopped ] || fail "Source container $1 should be stopped."
        [ "$(vzlist $2 -Ho status)" == stopped ] || fail "Destination container $2 should be stopped."
   [ ${src##*.} = ${dest##*.} -a ${src%%.*} = ${dest%%.*} ] || confirmfix "$1" "$2";
}

[ $# -eq 2 ] || fail "Not enough parameters. Usage ct_replace_vz.sh RESTOREDCTID NEWCTID";
infomsg "This script will put the content of restored container - $1 to the new container - $2";
infomsg "The IP address, hostname, name, ssh keys - will be saved in the new container as it should be.";
check "Source" "$1";
check "Destination" "$2";
validate "$1" "$2";
f_checkcomputetype "$1" "$2";

STAMP=$(date +%Y-%m-%dT%H-%M)

# replace() - replace fake container with migrated one
# 1: migrated container id
# 2: fake container id
replace() {
   local eid="/vz/private/$2/.vza/eid.conf"
   local uuid=$(cat "$eid")
   local pvaid="/var/opt/pva/agent/etc/configs/$uuid"
   local list=( '/etc/hosts' '/etc/sysconfig/iptables' '/etc/sysconfig/network-scripts/route-*' )
   local ipaddress=$(grep 'IP_ADDRESS' /vz/private/$2/ve.conf)
   local nameserver=$(grep -r 'NAMESERVER' /vz/private/$2/ve.conf)
   local tmp

   infomsg "Replacing container $2 with $1 (uuid $uuid)";

   # Backup stuff
   cp /vz/private/$1/ve.conf /vz/private/$1/ve.conf.orig-$STAMP
   cp /vz/private/$2/ve.conf /vz/private/$1/ve.conf.clone-$STAMP

   # Inplace modify VZ config networking
   sed -ri \
      -e "s/IP_ADDRESS.*$/${ipaddress//\//\/}/" \
      -e "s/NAMESERVER.*$/$nameserver/" \
      "/vz/private/$1/ve.conf"

   vzctl --quiet mount $1
   vzctl --quiet mount $2

   find /vz/root/$1/etc/sysconfig/network-scripts -type f -name 'route-*' -exec mv {} {}.bak-$STAMP \;

   # Update ssh gate access
   ( cd /vz/root/$2; find -name authorized_keys; ) | \
   while read f
   do
      tmp=$(dirname /vz/root/$1/$f)
      ! mkdir -p $tmp &>/dev/null || {
         chmod 700 $tmp
         touch /vz/root/$1/$f
         chmod 600 /vz/root/$1/$f
      }
      cat /vz/root/$2/$f >>/vz/root/$1/$f
   done

   infomsg "Backup and copy various configs";
   for f in ${list[@]}
   do
      [ -f /vz/root/$2$f ] || continue
      find /vz/root/$1$f | grep -vE '[.]bak[-]' | \
      while read l
      do
         mv -f $l $l.bak-$STAMP
      done
      cp /vz/root/$2$f /vz/root/$1$(dirname $f)
   done

   vzctl --quiet umount $2
   vzctl --quiet umount $1

   # Move stuffi
   infomsg "Destroying old container"
   vzctl --quiet destroy $2
   vzmlocal $1:$2

  # should be changed UUID after vzmlocal 
  vzctl --quiet unregister $2
  sed "s/^UUID=.[0-9a-z-]*./UUID=\"$uuid\"/" -i /vz/private/$2/ve.conf
  prlctl register /vz/private/$2 --preserve-uuid &>/dev/null

   okmsg "Successfuly completed.";

}
replace $1 $2;

