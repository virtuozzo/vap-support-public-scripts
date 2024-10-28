#!/bin/bash

err(){ echo -e "\\033[1;31m$@\\033[0;39m"; exit 255; } ;
win(){ echo -e "\\033[1;32m$@\\033[0;39m"; exit 0; } ;
g_i(){ echo -e "\\033[1;32m$@\\033[0;39m"; } ;
c_i(){ echo -e "\\033[1;34m$@\\033[0;39m"; } ;
y_i(){ echo -e "\\033[1;33m$@\\033[0;39m"; } ;
r_i(){ echo -e "\\033[1;31m$@\\033[0;39m"; } ;
gr_i(){ echo -e "\\033[1;37m$@\\033[0;39m"; } ;

CLUSTER_NAME=$(find /etc/vstorage/clusters/* -type d 2>/dev/null | awk -F '/' {'print $NF'} | head -n 1 2>/dev/null);
[ -z $CLUSTER_NAME ] && err "This node is not participating in any VStorage cluster";
ls /etc/vstorage/clusters/$CLUSTER_NAME/auth_digest.key &>/dev/null;
GET_CN=$?;
[ $GET_CN -eq 0 ] || err "This node is not participating in any VStorage cluster";

c_i "Cluster name: $CLUSTER_NAME";

mount 2>/dev/null | grep -q -E "^pstorage://$CLUSTER_NAME|^vstorage://$CLUSTER_NAME" &>/dev/null;
GET_CL=$?;

readlink /vz/private 2>/dev/null | grep -q vstorage &>/dev/null
GET_LINK=$?;


[ $GET_CL -eq 0 ] && [ $GET_LINK -eq 0 ] && g_i "This server is a Client" || r_i "This server is not a client!";

vstorage -c $CLUSTER_NAME list-services > /tmp/cluster_$CLUSTER_NAME.info

cat /tmp/cluster_$CLUSTER_NAME.info | grep -qE 'CS[[:blank:]]' &>/dev/null;
GET_CS=$?;

[ $GET_CS -eq 0 ] && g_i "This server is a Chunk server" || r_i "This server is not a Chunk Server!";

cat /tmp/cluster_$CLUSTER_NAME.info | grep -qE 'MDS[[:blank:]]' &>/dev/null;
GET_MDS=$?;

[ $GET_MDS -eq 0 ] && g_i "This server is a MDS server" || r_i "This server isn't acting as MDS!";

GET_MASTER_MDS=$(vstorage -c $CLUSTER_NAME stat 2>/dev/null | grep -w 'M[[:blank:]]' | awk {'print $10'});
[ -z $GET_MASTER_MDS ] && err "Can't detect the Master MDS server!" || y_i "Master MDS is: $GET_MASTER_MDS";

