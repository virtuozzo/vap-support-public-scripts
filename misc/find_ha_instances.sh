#!/bin/bash

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



declare -A instance_ctid
declare -A instance_count

while read -r hostname ctid; do
  instance=$(echo "$hostname" | awk -F'[0-9]*[.]' '{print $1}')
  if [[ -n "$instance" ]]; then
    if [[ ${instance_count[$instance]+_} ]]; then
      instance_ctid["$instance"]+=" $ctid"
      instance_count["$instance"]=$((instance_count["$instance"] + 1))
    else
      instance_count["$instance"]=1
      instance_ctid["$instance"]="$ctid"
    fi
  fi
done < <(vzlist -Ho hostname,ctid | awk '($1 ~ /^(jelcore|jbilling|jstatistic|hcore|webgate|gate|resolver)/)')

for instance in "${!instance_ctid[@]}"; do
  if [[ ${instance_count[$instance]} -gt 1 ]]; then
    warnmsg "Both instances of [$instance] are on the same infra host: ${instance_ctid[$instance]}."
   # warnmsg "Disable and migrate offline one instance of [$instance] to another infra host, then start it there and enable"
  fi
done

