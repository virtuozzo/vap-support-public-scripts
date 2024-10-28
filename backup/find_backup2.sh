#!/bin/bash

while true; do
    echo -e "Enter the environment name \e[1;31m(without platform domain)\e[0m to find available backups:"
    read enviname
    if [[ $enviname =~ ^[0-9a-zA-Z-]+$ ]]; then
	break
    else
	echo -e "\e[1;31mCheck if the envname is correct!\e[0m"
        continue
    fi
done

echo -e "BACKUPS FOR MASK \"\e[1;32m${enviname}\e[0m\""; 
backup_path=$(grep $enviname $(prlsrvctl info 2>/dev/null | grep 'Backup path:' | awk {'print $3'})/*/*/base/ve.conf | grep -E "NAME" | awk -F ':' {'print $1'} | sort | uniq);
[ $? -ne 0 ] || \
#for path in $backup_path; 
#do echo -e "\e[1;33mBACKUPS FOR $(grep -w ^NAME $path | awk -F '"' '{print $2}' | uniq):\e[0m"; 
#prlctl backup-list $(grep -w ^UUID $path | awk -F '"' '{print $2}' | uniq) 2>/dev/null; echo -e; 
#done



declare -A uuid_to_name

# Initialize arrays to store unique UUIDs and names
unique_uuids=()
unique_names=()

# Loop through all paths in $backup_path
for path in $backup_path; do
  # Extract UUIDs from the current $path
  uuids=($(grep -w ^UUID $path | awk -F '"' '{print $2}'))

  # Extract unique names from the current $path
  names=($(grep -w ^NAME $path | awk -F '"' '{print $2}' | sort -u))

  # Add UUIDs and their corresponding names to the associative array
  for ((i = 0; i < ${#uuids[@]}; i++)); do
    uuid_to_name[${uuids[$i]}]=${names[$i]}
  done
done

# Extract unique UUIDs
unique_uuids=("${!uuid_to_name[@]}")

# Iterate through the unique UUIDs
for uuid in "${unique_uuids[@]}"; do
  name="${uuid_to_name[$uuid]}"
  
  echo -e "\e[1;33mUUID: $uuid\e[0m"  
  echo -e "\e[1;33mBACKUPS FOR $name:\e[0m"
  #echo -e "\e[1;33mBACKUPS FOR $(prlctl list -o name $uuid):\e[0m"
  echo -e "\e[1;33mCTID:$(echo "$name" | awk -F'.' '{print $2}')\e[0m"
  prlctl backup-list $uuid 2>/dev/null
  echo -e
done




#unique_uuids=()  # Initialize an empty array to store unique UUIDs
# Loop through all paths in $backup_path
#for path in $backup_path; do
  # Extract UUIDs from the current $path and add them to unique_uuids
 # unique_uuids+=($(grep -w ^UUID $path | awk -F '"' '{print $2}'))
#done

# Deduplicate UUIDs by converting the array to a set and back to an array
#unique_uuids=($(echo "${unique_uuids[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

# Iterate through the unique UUIDs and perform the desired action
#for uuid in "${unique_uuids[@]}"; do
 # echo -e "\e[1;33mUUID: $uuid\e[0m"
  # Output the unique name for this UUID
  #echo -e "\e[1;33mBACKUPS FOR $(prlctl list -Ho name $uuid):\e[0m"
  
  # Perform bkp list
  #prlctl backup-list $uuid 2>/dev/null
  #echo -e  
#done
