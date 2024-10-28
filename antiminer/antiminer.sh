#!/bin/bash
# version 2.0-b23 (beta)

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/root/bin:$PATH

# Export config file
. $(dirname $0)/$(basename $0).conf || { errorLog "No configuration file $(basename $0).conf found"; exit 1; }

errorLog(){
    echo "$(date +'%F %T') ERROR: $@" | tee -a $ERROR_LOG
}

# MySQL, ClamAV, jq should be installed on HNs
MYSQL=$(which mysql) || { errorLog "Please, install mysql"; exit 1; }
CLAMSCAN=$(which clamscan) || { errorLog "Please, install clamav"; exit 1; }
which jq 1>/dev/null || { errorLog "Please, install jq"; exit 1; }

# Remove temporary files 
rm -f $MINER_DETAILS $MINER_REPORT_DETAILS $CLAMAV_FOR_MAINTAINER $POOL_FOR_MAINTAINER $SIGNATURE_FOR_MAINTAINER $TMP_TOP $TMP_DESTROY_LOG $TMP_PROOF_LOG 2>/dev/null

apiErrorLog(){
    echo "$(date +'%F %T') ERROR: $@" | tee -a $TMP_DESTROY_LOG $DESTROY_LOG >/dev/null
}

apiSuccessLog(){
    echo "$(date +'%F %T') SUCCESS: $@" | tee -a $TMP_DESTROY_LOG $DESTROY_LOG >/dev/null
}

apiResult(){
    local result
    result="$(jq .response.result <<<$@)"
    [[ "$result" != 'null' ]] || result="$(jq .result <<<$@)"
    echo "${result:-1}"
}

apiError(){
    local error
    error="$(jq -r .response.error <<<$@)"
    [[ "$error" != 'null' ]] || error="$(jq -r .error <<<$@)"
    echo "${error:-'API error'}"
}

getRes() {
    local url resource=$1
    
    [[ -n "$resource" ]] || return
    
    url="${ANTIMINER_DOMAIN}/$resource"
    [ $(curl -s -o /dev/null -I -w "%{http_code}" $url) -ne 200 ] && errorLog "Can't reach $url" || wget $url -qNP ${TMP_DIR}
    [ $? -eq 0 ] || errorLog "Can't download $resource"
}

# Download mining tools and IP pool
getRes $MINER_TOOL_SIGNATURES
getRes $MINER_TOOL_NAMES
getRes $MINER_POOL_LIST

getUidByCtidApi(){
    local uid ctId=$1

    uid=$(timeout $TIMEOUT curl -ks "https://jca.${PLATFORM_DOMAIN}/JElastic/administration/cluster/rest/searchnodes" \
        -d "appid=cluster&token=$ADMIN_TOKEN" --data-urlencode "search={'searchText': $ctId}" | jq . 2>/dev/null)

    [ $(apiResult $uid) -eq 0 ] 2>/dev/null \
        && { USERID=$(jq -r '.array[] | select(.ctid == '$ctId') | .uid' <<<$uid); USERID=${USERID:-NULL}; } \
        || { USERID="NULL"; errorLog "Can't get uid: $(apiError $uid)"; }
}

getUidDetailsApi(){
    local userDetails
    getUidByCtidApi $1

    [[ x"$USERID" != x"NULL" ]] || { MINER_EMAIL="NULL"; MINER_GROUP="NULL"; MINER_PHONE_NUM="NULL"; return; }

    userDetails=$(timeout $TIMEOUT curl -ks "https://jca.${PLATFORM_DOMAIN}/JBilling/billing/account/rest/getaccounts" \
        -d "appid=cluster&filterField=uid&filterValue=$USERID&token=$ADMIN_TOKEN" | jq . 2>/dev/null)

    [ $(apiResult $userDetails) -eq 0 ] 2>/dev/null \
    && { MINER_EMAIL=$(jq -r .array[].email <<<$userDetails | sed 's/null/NULL/') || MINER_EMAIL="NULL"; \
        MINER_GROUP="$(jq -r .array[].group.name <<<$userDetails | sed 's/null/NULL/')/$(jq -r .array[].group.type <<<$userDetails | sed 's/null/NULL/')" || MINER_GROUP="NULL"; \
        MINER_PHONE_NUM=$(jq -r .array[].phoneNumber <<<$userDetails | sed 's/null/NULL/') || MINER_PHONE_NUM="NULL"; } \
    || { MINER_EMAIL="NULL"; \
        MINER_GROUP="NULL"; \
        MINER_PHONE_NUM="NULL"; \
        errorLog "Can't get userDetails: $(apiError $userDetails)"; }
}

getUserRegIpApi(){
    local regIp
    getUidByCtidApi $1

    [[ x"$USERID" != x"NULL" ]] || { MINER_REG_IP="NULL"; return; }

    regIp=$(timeout $TIMEOUT curl -ks "https://jca.${PLATFORM_DOMAIN}/1.0/development/scripting/rest/eval" \
        -d "uid=$USERID&script=GetUsersSignupInfo&session=$ADMIN_TOKEN&appid=jca" \
        --data-urlencode "startDate=2010-02-01 00:00:00" --data-urlencode "endDate=`date +%F` 23:59:59" | jq . 2>/dev/null)

    [ $(apiResult $regIp) -eq 0 ] 2>/dev/null \
    && { MINER_REG_IP=$(jq -r .response.objects[].data.userip <<<$regIp | grep -v 'null' | sort -u | head -1) || MINER_REG_IP="NULL"; } \
    || { MINER_REG_IP="NULL"; errorLog "Can't get Registration IP: $(apiError $regIp)"; }
}

getUserDataApi(){
    local ctId=$1
    getUidDetailsApi $ctId
    getUserRegIpApi $ctId
}

getUserDataDb() {
    local hivextApp query minerUid ctId=$1
    export MYSQL_PWD="${REPLYCA_PASS}"

    # Check DB connection
    timeout 10 $MYSQL -h $REPLYCA_HOST -u $REPLYCA_USER -e ";" 2> >(tee -a $MYSQL_ERROR_LOG >&2)
    [ $? -eq 0 ] || \
        { MINER_EMAIL="NULL"; MINER_GROUP="NULL"; MINER_PHONE_NUM="NULL"; MINER_REG_IP="NULL"; \
        errorLog "Can't connect to Replyca DB or credentials are incorrect"; return; }

    hivextApp=$($MYSQL -h $REPLYCA_HOST -u $REPLYCA_USER -B -N -e \
        "SELECT CONCAT ('hivext_app_',id) FROM hivext_users.application WHERE appid = 'database' ORDER BY id DESC LIMIT 1" 2> >(tee -a $MYSQL_ERROR_LOG >&2))

    minerUid=$($MYSQL -h $REPLYCA_HOST -u $REPLYCA_USER -B -N -e \
	"SELECT app_nodes.uid FROM hivext_jelastic.app_nodes app_nodes
         INNER JOIN hivext_jelastic.soft_node soft_node ON soft_node.env_id = app_nodes.id
         WHERE soft_node.osNode_id = $ctId" 2> >(tee -a $MYSQL_ERROR_LOG >&2)); minerUid=${minerUid:-NULL}

    MINER_EMAIL=$($MYSQL -h $REPLYCA_HOST -u $REPLYCA_USER -B -N -e \
        "SELECT email FROM hivext_users.user
        WHERE id = $minerUid" 2> >(tee -a $MYSQL_ERROR_LOG >&2)); MINER_EMAIL=${MINER_EMAIL:-NULL}

    MINER_GROUP=$($MYSQL -h $REPLYCA_HOST -u $REPLYCA_USER -B -N -e \
        "SELECT CONCAT(account_group.name,'/',
	        CASE
                WHEN account_group.type=0 THEN 'post'
                WHEN account_group.type=1 THEN 'billing'
                WHEN account_group.type=2 THEN 'beta'
                WHEN account_group.type=3 THEN 'trial'
                ELSE 'undefined'
            END)
        FROM hivext_jbilling.account account 
            INNER JOIN hivext_jbilling.account_group AS account_group ON account_group.id = account.group_id 
            WHERE account.uid = $minerUid" 2> >(tee -a $MYSQL_ERROR_LOG >&2)); MINER_GROUP=${MINER_GROUP:-NULL}

    MINER_PHONE_NUM=$($MYSQL -h $REPLYCA_HOST -u $REPLYCA_USER -B -N -e \
        "SELECT phoneNumber FROM hivext_users.user
        WHERE id = $minerUid" 2> >(tee -a $MYSQL_ERROR_LOG >&2)); MINER_PHONE_NUM=${MINER_PHONE_NUM:-NULL}

    if [[ -n $hivextApp ]]
    then
        MINER_REG_IP=$($MYSQL -h $REPLYCA_HOST -u $REPLYCA_USER -B -N -e \
            "SELECT f_data_value FROM $hivextApp.t_Signup_map_f_data
            WHERE f_Signup_id IN (SELECT id FROM $hivextApp.t_Signup
            WHERE f_user IN (SELECT id FROM $hivextApp.t_JUser
            WHERE f_data_key='userip' AND f_uid = $minerUid)) LIMIT 1" 2> >(tee -a $MYSQL_ERROR_LOG >&2)); MINER_REG_IP=${MINER_REG_IP:-NULL}
    fi
}

getUserData(){
    local ctId=$1

    case $GET_USER_DATA_MODE in
        "db")
    getUserDataDb $ctId
    ;;
        "api")
    getUserDataApi $ctId
    ;;
        *)
    getUserDataDb $ctId
    ;;
    esac
}

getHostName() {
    local ctId=$1

    if [[ -n "$ctId" ]]; then
        HOSTNAME=$(vzlist -Ho hostname $ctId 2>/dev/null) && { [ ${#HOSTNAME} -ne 1 ] || HOSTNAME=${HOSTNAME/-/NULL}; } || HOSTNAME="NULL"
    fi
}

signatureChecker() {
    local clamScanToolSignResult clamScanResult signCheck signature signatureTrigger checkSignDbNew
    local ctId="$1"
    local minerToolName="$2"
    local minerProcPid="$3"
    local fullProcName="$4"
    local skip="$5"
    export MYSQL_PWD="${ANALYZER_PASS}"

    if [[ -f /proc/$minerProcPid/exe ]]; then
        signature=$(cat /proc/$minerProcPid/exe 2>/dev/null | sigtool --hex-dump | head -c 4096)

        CHECK_SIGN_DB=$($MYSQL -h $ANALYZER_HOST -P $ANALYZER_PORT -u $ANALYZER_USER -B -N -e \
            "SELECT id FROM antiminer.miner_tool_signature WHERE miner_tool_signature=\"$signature\"" 2> >(tee -a $MYSQL_ERROR_LOG >&2))
        CHECK_SIGN_DB=${CHECK_SIGN_DB:-0}

	[[ x"$skip" != x"true" ]] || return

	let clamScanToolSignResult=$($CLAMSCAN --max-filesize=500M -d ${TMP_DIR}/${MINER_TOOL_SIGNATURES} -ir /proc/$minerProcPid/exe 2>/dev/null | grep FOUND | wc -l)

        [[ $clamScanToolSignResult -ne 0 ]] || let clamScanResult=$($CLAMSCAN --max-filesize=500M -ir /proc/$minerProcPid/exe 2>/dev/null | grep FOUND | wc -l)

        if [[ $clamScanToolSignResult -eq 0 ]]; then
            signatureMail=$(sed -E 's/(.{100})/&\n/g' <<<$(echo "$minerToolName:6:*:$(echo $signature | head -c 2048)"))

            checkSignDbNew=$($MYSQL -h $ANALYZER_HOST -P $ANALYZER_PORT -u $ANALYZER_USER -B -N -e \
                "SELECT id FROM antiminer.miner_tool_signature_new WHERE miner_tool_signature=\"$signature\"" 2> >(tee -a $MYSQL_ERROR_LOG >&2))

            if ! cat $SIGNATURE_FOR_MAINTAINER 2>/dev/null | sed ':a;N;$!ba; s/\n//g' | grep -qw "$signature" && [[ -n $signature ]] && [[ -z $checkSignDbNew ]] && [[ $CHECK_SIGN_DB -eq 0 ]]; then
                echo -e "$ctId\t$(awk -F. '{print $1}' <<<$HOSTNAME)\t$minerProcPid\t$fullProcName\t" >> $SIGNATURE_FOR_MAINTAINER
                echo "$signatureMail" >> $SIGNATURE_FOR_MAINTAINER

                $MYSQL -h $ANALYZER_HOST -P $ANALYZER_PORT -u $ANALYZER_USER -e  \
                    "INSERT INTO antiminer.miner_tool_signature_new (ctid,platform_name,hostname,miner_tool_name,pid,full_proc_name,miner_tool_signature) \
		     VALUES ($ctId,\"$PLATFORM_NAME\",\"$HOSTNAME\",\"$minerToolName\",$minerProcPid,\"$fullProcName\",\"$signature\")" 2> >(tee -a $MYSQL_ERROR_LOG >&2)
            fi
        elif [[ $clamScanToolSignResult -gt 0 ]]; then
            MINER_PROB=99
            CLAMAV_STATUS=1
        elif [[ $clamScanResult -gt 0 ]]; then
            MINER_PROB=85
            CLAMAV_STATUS=0
        fi
    fi
}

checkTrusted(){
    local shortProcName="$1"
    local hexIp="$2"
    local minerIp="$3"
    shortProcName=${shortProcName:-NULL}; hexIp=${hexIp:-NULL}; minerIp=${minerIp:-NULL}

    grep -qx "$(sed ':a;N;$!ba; s/\n/\\|/g' $TRUSTED_SHORT_DOMAIN 2>/dev/null)" <<<$(awk -F. '{print $1}' <<<$HOSTNAME) \
    || grep -qx "$(sed ':a;N;$!ba; s/\n/\\|/g' $TRUSTED_TOOL_NAME 2>/dev/null)" <<<$shortProcName \
    || grep -qx "$(sed ':a;N;$!ba; s/\n/\\|/g' $TRUSTED_HEX_IP 2>/dev/null)" <<<$hexIp \
    || grep -qx "$(sed ':a;N;$!ba; s/\n/\\|/g' $TRUSTED_POOL_IP 2>/dev/null)" <<<$minerIp \
    || grep -qx "$(sed ':a;N;$!ba; s/\n/\\|/g' $TRUSTED_EMAIL 2>/dev/null)" <<<$MINER_EMAIL \
    || grep -qx "$(sed ':a;N;$!ba; s/\n/\\|/g' $TRUSTED_GROUP 2>/dev/null)" <<<$(awk -F/ '{print $1}' <<<$MINER_GROUP) \
    && echo true || echo false
}

minerSearchOutput() {
    local miner sign_id minerPoolDomain minerPoolDomainCount reportDetails
    local hexIp="$1"
    local ctId="$2"
    local minerIp="$3"
    local minerProcId="$4"
    local fullProcName="$5"
    local shortProcName="$6"
    local skip="$7"
    export MYSQL_PWD="${ANALYZER_PASS}"

    minerIp=${minerIp:-NULL}
    hexIp=${hexIp:-NULL}
    shortProcName=${shortProcName:-NULL}

    [[ x"$(checkTrusted $shortProcName $hexIp $minerIp)" == x"true" ]] && return

    if [[ -z $hexIp ]]; then
        minerPoolDomain="NULL"
    else
        minerPoolDomainCount=$(awk -v hex=$hexIp '$3==hex {print $1}' ${TMP_DIR}/${MINER_POOL_LIST} | wc -l)
        [[ $minerPoolDomainCount -ge 2 ]] && \
            minerPoolDomain=$(echo "$(awk -v hex=$hexIp '$3==hex {print $1}' ${TMP_DIR}/${MINER_POOL_LIST} | head -1)...+$((minerPoolDomainCount-1))") || \
            minerPoolDomain=$(awk -v hex=$hexIp '$3==hex {print $1}' ${TMP_DIR}/${MINER_POOL_LIST})
    fi
    minerPoolDomain=${minerPoolDomain:-NULL}

    signatureChecker "$minerCtId" "$shortProcName" "$minerProcId" "$fullProcName" "$skip"

    reportDetails="$ctId$(printf '\t')$(awk -F. '{print $1}' <<<$HOSTNAME)$(printf '\t')$minerIp$(printf '\t')$minerPoolDomain$(printf '\t')$minerProcId$(printf '\t')$MINER_EMAIL$(printf '\t')$MINER_GROUP$(printf '\t')$MINER_REG_IP$(printf '\t')$MINER_PHONE_NUM$(printf '\t')$MINER_PROB$(printf '\t')$fullProcName"
    ! grep -q "$ctId.*$minerProcId.*$MINER_EMAIL.*$MINER_GROUP.*$MINER_PROB.*$fullProcName" $MINER_DETAILS 2>/dev/null || return

    # Instert into antiminer DB if user is trial and there is no occurancies yet.
    # This helps to see statistics and not to show personal data of one hoster to another for groups differ from trial if hoster's stuff will check DB
    if [[ -n $MINER_EMAIL && $MINER_EMAIL != "NULL" && $MINER_GROUP == *"trial"* ]]; then
        miner=$($MYSQL -h $ANALYZER_HOST -P $ANALYZER_PORT -u $ANALYZER_USER -B -N -e \
            "SELECT user_email FROM antiminer.miner_details WHERE user_email=\"$MINER_EMAIL\" AND platform_name LIKE \"%$PLATFORM_NAME%\"" 2> >(tee -a $MYSQL_ERROR_LOG >&2))
        miner=${miner:-NULL}

        if [[ "$miner" == "NULL" ]]; then
             $MYSQL -h $ANALYZER_HOST -P $ANALYZER_PORT -u $ANALYZER_USER -e \
            "INSERT INTO antiminer.miner_details (ctid,platform_name,hostname,miner_pool_ip,pid,user_email,user_group,reg_ip,phone_number,clamav_status,full_proc_name,sign_id) \
            VALUES ($ctId,\"$PLATFORM_NAME\",\"$HOSTNAME\",\"$minerIp\",$minerProcId,\"$MINER_EMAIL\",\"$MINER_GROUP\", \
            \"$MINER_REG_IP\",\"$MINER_PHONE_NUM\",$CLAMAV_STATUS,\"$fullProcName\",$CHECK_SIGN_DB)" 2> >(tee -a $MYSQL_ERROR_LOG >&2)
        fi
    fi
    [[ $CHECK_SIGN_DB -eq 0 ]] && sign_id="" || sign_id=" (sign id $CHECK_SIGN_DB)"
    echo -e "$reportDetails" >> $MINER_DETAILS
    echo "$(date '+%F %T') User $MINER_EMAIL (group $MINER_GROUP) has been recognized as miner with probability ${MINER_PROB}%${sign_id}, CT $ctId, proc: $fullProcName." | tee -a $DETECTION_LOG >/dev/null
}

searchByToolNameInProcess() {
    local toolNames processNames procId pidReportDetails minerCtId socketIdList socketId hexIpList hexIp minerIp fullProcName shortProcName hexIpCheck minerPoolDomain
    toolNames=$(sed ':a;N;$!ba; s/\n/|/g' ${TMP_DIR}/${MINER_TOOL_NAMES})

    if [[ -n $toolNames ]]; then
        processNames=($(find /proc/[0-9]*/cmdline 2>/dev/null | xargs -n64 -P8 grep -awlE "$toolNames" 2>/dev/null | awk -F '/' '{print $3}'))

        for procId in ${processNames[@]}; do
            minerCtId=$(grep "^envID:" /proc/$procId/status 2>/dev/null | awk '{print $2}' | grep -xE '[0-9]+')

            if [[ -z $minerCtId && -f /proc/$procId/exe ]]; then
                minerCtId=$(vzpid $procId | awk '{print $2}' | grep -xE '[0-9]+')
            fi

            if [[ -n $minerCtId && $minerCtId -gt 0 && -d /proc/$procId/fd/ ]]; then
                socketIdList=($(readlink /proc/$procId/fd/[0-9]* | grep -E '^socket:\[[0-9]+\]$' | sed 's/socket\:\[\(.*\)\]/\1/'))

                getHostName $minerCtId
                getUserData $minerCtId
            fi

            for socketId in ${socketIdList[@]}; do
                hexIpList=($(awk -v socketId=$socketId '$10 == socketId {print $3}' /proc/$procId/net/tcp 2>/dev/null | awk -F: '{print $1}' | grep -v '00000000\|7F000001'))

                for hexIp in $(echo ${hexIpList[@]} | tr ' ' '\n' | sort -u | tr '\n' ' '); do
                    minerIp=$(sed 's/.\{2\}/&./g' <<<$hexIp | awk -F "." '{print strtonum( "0x" $4 )"."strtonum( "0x" $3 )"."strtonum( "0x" $2 )"."strtonum( "0x" $1 )}' \
                        | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
                        | grep -vE '(^0\.)|(^10\.)|(^100\.6[4-9]\.)|(^100\.[7-9]\d\.)|(^100\.1[0-1]\d\.)|(^100\.12[0-7]\.)|(^127\.)|(^169\.254\.)|(^172\.1[6-9]\.)|(^172\.2[0-9]\.)|(^172\.3[0-1]\.)|(^192\.0\.0\.)|(^192\.0\.2\.)|(^192\.88\.99\.)|(^192\.168\.)|(^198\.1[8-9]\.)|(^198\.51\.100\.)|(^203.0\.113\.)|(^22[4-9]\.)|(^23[0-9]\.)|(^24[0-9]\.)|(^25[0-5]\.)|(^(8\.){2}[8,4]\.[8,4]$)|(^1\.[0-1]\.[0-1]\.1$)|(^208\.67\.22[0,2]\.22[0,2]$)|(^(9\.){3}9$)|(^149(\.112){3}$)')

                    if [[ -n $minerIp && -f /proc/$procId/cmdline && -f /proc/$procId/exe ]]; then
                        fullProcName=$(cat /proc/$procId/cmdline | sed 's/[[:space:]]\{1,\}/-/g')
                        shortProcName=$(readlink /proc/$procId/exe | awk -F/ '{print $NF}' | sed 's/[[:space:]]\{1,\}/-/g')
                        let hexIpCheck=$(grep "${hexIp}$" ${TMP_DIR}/${MINER_POOL_LIST} | wc -l)

                        if [[ $hexIpCheck -eq 0 ]]; then
                             MINER_PROB=60
                            grep -q "$minerIp.*$fullProcName" $POOL_FOR_MAINTAINER 2>/dev/null \
                            || echo -e "$minerIp\t$(awk -F. '{print $1}' <<<$HOSTNAME)\t$MINER_EMAIL\t$MINER_GROUP\t$fullProcName" >> $POOL_FOR_MAINTAINER
                        else
                            MINER_PROB=70
                        fi

                        minerSearchOutput "$hexIp" "$minerCtId" "$minerIp" "$procId" "$fullProcName" "$shortProcName"
                    fi
                done
            done
        done
    fi
}

searchByConnection() {
    local hexIPs IPs conn hexConn procNetTcpList procId ctReportDetails minerCtId socketIdList socketId hexIpList hexIp minerIp shortProcName fullProcName
    hexIPs=$(awk '{print $3}' ${TMP_DIR}/${MINER_POOL_LIST} | sed ':a;N;$!ba; s/\n/|/g')
    IPs=$(awk '{print $2}' ${TMP_DIR}/${MINER_POOL_LIST} | sed ':a;N;$!ba; s/\n/|/g')
    conn=$(grep -E "ESTABLISHED.*dst=($IPs)" /proc/net/nf_conntrack 2>/dev/null | awk '{print $8}' | sort -u | awk -F= '{print $2}' | sed ':a;N;$!ba; s/\n/|/g')

    if [[ -n $conn ]]; then
	hexConn=$(awk "\$2 ~ /^($conn)$/ {print \$3}" ${TMP_DIR}/${MINER_POOL_LIST} | sort -u | sed ':a;N;$!ba; s/\n/|/g')
	[[ -n $hexConn ]] || return
        procNetTcpList=($(find /proc/[0-9]*/net/tcp 2>/dev/null | xargs -n64 -P8 grep -alE "$hexConn" 2>/dev/null | awk -F '/' '{print $3}'))

        for procId in ${procNetTcpList[@]}; do
            minerCtId=$(grep "^envID:" /proc/$procId/status 2>/dev/null | awk '{print $2}' | grep -xE '[0-9]+')

            if [[ -z $minerCtId && -f /proc/$procId/exe ]]; then
                    minerCtId=$(vzpid $procId | awk '{print $2}' | grep -xE '[0-9]+')
            fi

            ctReportDetails=$(awk "\$1 == $minerCtId" $MINER_DETAILS 2>/dev/null)
            [[ -z $ctReportDetails ]] || continue

            if [[ -n $minerCtId && $minerCtId -gt 0 && -d /proc/$procId/fd/ ]]; then
                socketIdList=($(readlink /proc/$procId/fd/[0-9]* | grep -E '^socket:\[[0-9]+\]$' | sed 's/socket\:\[\(.*\)\]/\1/'))

                getHostName $minerCtId
                getUserData $minerCtId
            fi

            for socketId in ${socketIdList[@]}; do
                hexIpList=($(awk -v socketId=$socketId '$10 == socketId {print $3}' /proc/$procId/net/tcp 2>/dev/null | awk -F: '{print $1}' | grep -wE "$hexIPs" | grep -v '00000000\|7F000001'))

                for hexIp in $(echo ${hexIpList[@]} | tr ' ' '\n' | sort -u | tr '\n' ' '); do
                    minerIp=$(sed 's/.\{2\}/&./g' <<<$hexIp | awk -F "." '{print strtonum( "0x" $4 )"."strtonum( "0x" $3 )"."strtonum( "0x" $2 )"."strtonum( "0x" $1 )}' \
                        | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
                        | grep -vE '(^0\.)|(^10\.)|(^100\.6[4-9]\.)|(^100\.[7-9]\d\.)|(^100\.1[0-1]\d\.)|(^100\.12[0-7]\.)|(^127\.)|(^169\.254\.)|(^172\.1[6-9]\.)|(^172\.2[0-9]\.)|(^172\.3[0-1]\.)|(^192\.0\.0\.)|(^192\.0\.2\.)|(^192\.88\.99\.)|(^192\.168\.)|(^198\.1[8-9]\.)|(^198\.51\.100\.)|(^203.0\.113\.)|(^22[4-9]\.)|(^23[0-9]\.)|(^24[0-9]\.)|(^25[0-5]\.)|(^(8\.){2}[8,4]\.[8,4]$)|(^1\.[0-1]\.[0-1]\.1$)|(^208\.67\.22[0,2]\.22[0,2]$)|(^(9\.){3}9$)|(^149(\.112){3}$)')

                    if [[ -n $minerIp && -f /proc/$procId/cmdline && -f /proc/$procId/exe ]]; then
                        fullProcName=$(cat /proc/$procId/cmdline | sed 's/[[:space:]]\{1,\}/-/g')
                        shortProcName=$(readlink /proc/$procId/exe | awk -F/ '{print $NF}' | sed 's/[[:space:]]\{1,\}/-/g')
                        MINER_PROB=50

                        minerSearchOutput "$hexIp" "$minerCtId" "$minerIp" "$procId" "$fullProcName" "$shortProcName"
                    fi
                done
            done
        done
    fi
}

searchByTimeConsumeProcInTop() {

    local processIds procId topProcList tmpProcId pidReportDetails threatName clamScanToolSignResult clamScanResult fullProcName shortProcName minerCtId socketIdList socketId hexIpList hexIp
    local minerIp='NULL'
    # CPU time usage for user CTIDs (ctid > 1000) https://unix.stackexchange.com/a/429705
    local ctidStartNum=1000
    # How many the most CPU time consuming processes to check??
    local procNumber=3
    
    processIds=($(find /proc/ -maxdepth 1 -type d -regex '.*/[0-9]+' -print 2>/dev/null | sed 's/\/proc\///'))

    for procId in ${processIds[@]}; do
        if [[ $(grep "^envID:" /proc/$procId/status 2>/dev/null | awk '{print $2}' | grep -xE '[0-9]+') -gt $ctidStartNum && -f /proc/$procId/stat ]]; then
            echo "$procId $(awk '{print $14+$15+$16+$17}' /proc/$procId/stat 2>/dev/null )" >> $TMP_TOP
        fi
    done

    # Top current $procNumber CPU consumers + top $procNumber CPU time consumers overall processes time
    topProcList=($(sort -nk 2 $TMP_TOP 2>/dev/null | awk '{print $1}' | tail -n $procNumber) $(ps aux | sort -nrk 3,3 | head -n $procNumber | awk '{print $2}'))

    for tmpProcId in $(echo "${topProcList[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '); do
        let clamScanToolSignResult=$($CLAMSCAN --max-filesize=500M -d ${TMP_DIR}/${MINER_TOOL_SIGNATURES} -ir /proc/$tmpProcId/exe 2>/dev/null | grep FOUND | sed s/.UNOFFICIAL//g | wc -l)

        if [[ $clamScanToolSignResult -eq 0 && -f /proc/$tmpProcId/exe ]]; then
            threatName=$($CLAMSCAN --max-filesize=500M -ir /proc/$tmpProcId/exe 2>/dev/null | grep FOUND | awk '{print $2}' | head -1 2>/dev/null)
            let clamScanResult=$(echo $threatName | wc -w)
        fi

        if [[ ( $clamScanToolSignResult -eq 1 || $clamScanResult -eq 1 ) && -f /proc/$tmpProcId/cmdline && -f /proc/$tmpProcId/exe && -f /proc/$tmpProcId/status ]]; then
            [[ $clamScanToolSignResult -eq 1 ]] && { MINER_PROB=90; CLAMAV_STATUS=1; } || { MINER_PROB=80; CLAMAV_STATUS=0; }
            fullProcName=$(cat /proc/$tmpProcId/cmdline | sed 's/[[:space:]]\{1,\}/-/g')
            shortProcName=$(readlink /proc/$tmpProcId/exe | awk -F/ '{print $NF}' | sed 's/[[:space:]]\{1,\}/-/g')
            minerCtId=$( grep "^envID:" /proc/$tmpProcId/status 2>/dev/null | awk '{print $2}' | grep -xE '[0-9]+' )

            if [[ -z "$minerCtId" && -f /proc/$tmpProcId/exe ]]; then
                minerCtId=$(vzpid $tmpProcId | awk '{print $2}' | grep -xE '[0-9]+')
            fi

            ctReportDetails=$(awk "\$1 == $minerCtId" $MINER_DETAILS 2>/dev/null)
            [[ -z $ctReportDetails && -f /proc/$tmpProcId/exe ]] || continue

            if [[ -n "$minerCtId" && "$minerCtId" -gt 0 && -d /proc/$tmpProcId/fd/ ]]; then
                socketIdList=($(readlink /proc/$tmpProcId/fd/[0-9]* | grep -E '^socket:\[[0-9]+\]$' | sed 's/socket\:\[\(.*\)\]/\1/'))
                getHostName $minerCtId
                getUserData $minerCtId
            fi

	    [[ -n "$socketIdList" ]] || { minerSearchOutput "" "$minerCtId" "" "$tmpProcId" "$(echo $([[ $clamScanResult -gt 0 ]] && echo "(${threatName})")${fullProcName})" "$shortProcName" "true"; continue; }

            for socketId in ${socketIdList[@]}; do
                hexIpList=($(awk -v socketId=$socketId '$10 == socketId {print $3}' /proc/$tmpProcId/net/tcp 2>/dev/null | awk -F: '{print $1}' | grep -v '00000000\|7F000001'))

		[[ -n "$hexIpList" ]] || { minerSearchOutput "" "$minerCtId" "" "$tmpProcId" "$(echo $([[ $clamScanResult -gt 0 ]] && echo "(${threatName})")${fullProcName})" "$shortProcName" "true"; continue; }

                for hexIp in $(echo ${hexIpList[@]} | tr ' ' '\n' | sort -u | tr '\n' ' '); do
                    minerIp=$(echo $hexIp | sed 's/.\{2\}/&./g' | awk -F "." '{print strtonum( "0x" $4 )"."strtonum( "0x" $3 )"."strtonum( "0x" $2 )"."strtonum( "0x" $1 )}' \
                        | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
                        | grep -vE '(^0\.)|(^10\.)|(^100\.6[4-9]\.)|(^100\.[7-9]\d\.)|(^100\.1[0-1]\d\.)|(^100\.12[0-7]\.)|(^127\.)|(^169\.254\.)|(^172\.1[6-9]\.)|(^172\.2[0-9]\.)|(^172\.3[0-1]\.)|(^192\.0\.0\.)|(^192\.0\.2\.)|(^192\.88\.99\.)|(^192\.168\.)|(^198\.1[8-9]\.)|(^198\.51\.100\.)|(^203.0\.113\.)|(^22[4-9]\.)|(^23[0-9]\.)|(^24[0-9]\.)|(^25[0-5]\.)|(^(8\.){2}[8,4]\.[8,4]$)|(^1\.[0-1]\.[0-1]\.1$)|(^208\.67\.22[0,2]\.22[0,2]$)|(^(9\.){3}9$)|(^149(\.112){3}$)')

                    if [[ -n $minerIp ]]; then
                        let hexIpCheck=$(grep "${hexIp}$" ${TMP_DIR}/${MINER_POOL_LIST} | wc -l)
                        if [[ $hexIpCheck -eq 0 && $clamScanToolSignResult -eq 1 ]]; then
                            grep -q "$minerIp.*$fullProcName" $POOL_FOR_MAINTAINER 2>/dev/null \
                            || echo -e "$minerIp\t$(awk -F. '{print $1}' <<<$HOSTNAME)\t$MINER_EMAIL\t$MINER_GROUP\t$fullProcName" >> $POOL_FOR_MAINTAINER
                        elif [[ $hexIpCheck -gt 0 && $clamScanToolSignResult -eq 1 ]]; then
                            MINER_PROB=99
                        fi
                    fi

                    minerSearchOutput "$hexIp" "$minerCtId" "$minerIp" "$tmpProcId" "$(echo $([[ $clamScanResult -gt 0 ]] && echo "(${threatName})")${fullProcName})" "$shortProcName" "true"
                done
            done
        elif [[ ( $clamScanToolSignResult -gt 1 || $clamScanResult -gt 1 ) && -f /proc/$tmpProcId/cmdline ]]; then
            echo -e "$tmpProcId\t$(cat /proc/$tmpProcId/cmdline)\t$(( clamScanToolSignResult>1 ? clamScanToolSignResult : clamScanResult ))" >> $CLAMAV_FOR_MAINTAINER
        fi
    done
}

changeMinerStatusUsage(){
cat << EOF
Make sure APPID, PLATFORM_DOMAIN, ADMIN_TOKEN, MINER_PROCESSING variables are correctly specifed in $(basename $0).conf
EOF
}

apiChangeMinerStatusLog(){
        awk "\$6==\"$1\" && \$10>=$MINER_PROB_PROC_MIN {print}" $MINER_DETAILS | sort -nk10 | tail -1 | tee -a $TMP_PROOF_LOG $DESTROY_LOG >/dev/null
        if [[ -s $TMP_DESTROY_LOG && ! -s $TMP_PROOF_LOG ]]; then
            echo "[$(date '+%F %T')] There were no miner proofs found" | tee -a $TMP_PROOF_LOG $DESTROY_LOG >/dev/null
        fi
}

apiChangeMinerStatus(){
    local minerEmail checkUser minerUid key note insertNote deactivateUser destroyUser suspendUser

    # If no parameters - show usage
    [ $# -ne 0 ] || { changeMinerStatusUsage; exit 1; }
    
    for minerEmail in $(awk "\$6!=\"NULL\" && (\$7~/\/trial$/ || \$7~/^($(sed 's/,/|/g' <<<$GROUP_NAME_PROC))\//) && \$10>=$MINER_PROB_PROC_MIN {print \$6}" $MINER_DETAILS 2>/dev/null | sort | uniq); do
        checkUser=$(timeout $TIMEOUT curl -ks "https://jca.${PLATFORM_DOMAIN}/1.0/users/account/rest/checkuser" \
            -d "token=$ADMIN_TOKEN&appid=$APPID" --data-urlencode "login=$minerEmail" | jq . 2>/dev/null)

        if [ $(apiResult $checkUser) -eq 0 ] 2>/dev/null; then
            minerUid=$(jq -r .uid <<<$checkUser)

            case "$1" in
                deactivate)
                    deactivateUser=$(timeout $TIMEOUT curl -ks  "https://jca.${PLATFORM_DOMAIN}/1.0/billing/account/rest/setaccountstatus" \
                        -d "appid=$APPID&token=$ADMIN_TOKEN&uid=$minerUid&status=2" | jq . 2>/dev/null)

                    [ $(apiResult $deactivateUser) -eq 0 ] 2>/dev/null \
                        && apiSuccessLog "User $minerEmail was deactivated" \
                        || apiErrorLog "User $minerEmail was not deactivated: $(apiError $deactivateUser)"
                    ;;
                destroy)
                    destroyUser=$(timeout $TIMEOUT curl -ks  "https://jca.${PLATFORM_DOMAIN}/1.0/billing/account/rest/setaccountstatus" \
                        -d "appid=$APPID&token=$ADMIN_TOKEN&uid=$minerUid&status=3" | jq . 2>/dev/null)

                    [ $(apiResult $destroyUser) -eq 0 ] 2>/dev/null \
                        && apiSuccessLog "User $minerEmail was destroyed" \
                        || apiErrorLog "User $minerEmail was not destroyed: $(apiError $destroyUser)"
                    ;;
                simulate)
                    apiSuccessLog "(User status change simulation) Status of user $minerEmail can be potentially changed"
                    ;;
                none|disable|false|"")
                    [[ x"$3" == x"true" ]] || continue
                    ;;
                *)
                    changeMinerStatusUsage
                    exit 1
                    ;;
            esac

            case "$2" in
                "")
                    note="Miner $(date +%F_%X)"
                    ;;
                *)
                    note=$2
                    ;;
            esac

            insertNote=$(timeout $TIMEOUT curl -ks "https://jca.${PLATFORM_DOMAIN}/1.0/billing/account/rest/setusernote" \
                -d "uid=$minerUid&note=$note&session=$ADMIN_TOKEN&appid=$APPID" | jq . 2>/dev/null)

            [ $(apiResult $insertNote) -eq 0 ] 2>/dev/null \
                && apiSuccessLog "Note \"$note\" for $minerEmail was inserted" \
                || apiErrorLog "Note \"$note\" for $minerEmail was not inserted: $(apiError $insertNote)"

            case "$3" in
                true)
		    [[ x"$1" != x"simulate" ]] || { apiChangeMinerStatusLog $minerEmail; continue; }
                    suspendUser=$(timeout $TIMEOUT curl -ks "https://jca.${PLATFORM_DOMAIN}/1.0/billing/account/rest/suspenduser" \
                        -d "appid=$APPID&token=$ADMIN_TOKEN&uid=$minerUid" | jq . 2>/dev/null)

                    [ $(apiResult $suspendUser) -eq 0 ] 2>/dev/null \
                        && apiSuccessLog "User $minerEmail was suspended" \
                        || apiErrorLog "User $minerEmail was not suspended: $(apiError $suspendUser)"
                    ;;
                *)
		    apiChangeMinerStatusLog $minerEmail
                    continue
                    ;;
            esac
        else
            apiErrorLog "Can't identify uid for $minerEmail because of error: $(apiError $checkUser). Can't change user status"
        fi

        apiChangeMinerStatusLog $minerEmail
    done

    [ ! -f "$TMP_PROOF_LOG" ] || { sendEmail $TMP_PROOF_LOG $EMAIL destroy $TMP_DESTROY_LOG; echo -- >> $DESTROY_LOG; }
}

sendEmail(){
    local text=$1
    local to=$2
    local mode=$3
    local appendix=$4

    if [[ -s $text && -n $to ]]; then
	local hostnameDomain=$(hostname -d)
        local mailTmp=$(mktemp)
        local from="$PLATFORM_NAME <$(hostname -s)@${hostnameDomain:-$(hostname -s)}>"
        local subject=""
        local body=""

        case $mode in
            'tool')
                subject="[MAINTENANCE] New minertool signature detected on $(hostname -s) ($(date +'%F %H:%M UTC'))"
                body="Please, refer internal Support instructions about further actions:\n"
                ;;
                
            'clamav')
                subject="[MAINTENANCE] ClamAV result is unexpected on $(hostname -s) ($(date +'%F %H:%M UTC'))"
                body="Please, check in more detail why ClamAV result is unexpected on $(hostname -s) and `
                `refer internal Support instructions about further actions (expected result is 0 or 1):\n\n`
                `PID\tPROCESS\tMATCHES_NUMBER"
                ;;

            'pool')
                subject="[MAINTENANCE] New minerpool IP(s) detected on $(hostname -s) ($(date +'%F %H:%M UTC'))"
                body="Please, check in more detail why there is no connection IP/domain in miner pool `
                `for below environment(s) on $(hostname -s) and refer internal Support instructions about further actions:\n\n`
                `MINERPOOL_IP\tSHORT_DOMAIN\tEMAIL\tGROUP/TYPE\tPROCESS"
                ;;

            'detect')
                subject="[MINERS DETECT] Miner CT(s) has been detected on $(hostname -s) ($(date +'%F %H:%M UTC'))"
                body="Attention! Miners are detected on $(hostname -s).\n`
                `Please, find the suspected users(s) in JCA and take measures if it was not done yet automatically by this script:\n\n`
                `CTID\tSHORT_DOMAIN\tMINERPOOL_IP\tMINERPOOL_DOMAIN(S)\tPID\tEMAIL\tGROUP/TYPE\tREG_IP\tPHONE_NUMBER\tMINER_PROB(%)\tPROCESS"
                ;;

            'destroy')
                subject="[MINERS STATUS] Owner(s) status of miner CT(s) has been changed ($(date +'%F %H:%M UTC'))"
                body="Attention! Status of detected miners has been changed.\n`
                `Please, find the information below:\n\n`
                `CTID\tSHORT_DOMAIN\tMINERPOOL_IP\tMINERPOOL_DOMAIN(S)\tPID\tEMAIL\tGROUP/TYPE\tREG_IP\tPHONE_NUMBER\tMINER_PROB(%)\tPROCESS"
                ;;
        esac

        echo "From: $from" > $mailTmp
        echo "To: $to" >> $mailTmp
        echo "Subject: $subject" >> $mailTmp
        echo >> $mailTmp

        [[ -z $body ]] || echo -e "$body" >> $mailTmp
        [[ x"$mode" == x"tool" || x"$mode" == x"maintenance" ]] && cat $text >> $mailTmp || cat $text | sort -k6 >> $mailTmp

        if [[ $# -ge 4 && -n $appendix ]]; then
            echo "" >> $mailTmp
            echo "User status log:" >> $mailTmp
            cat $appendix >> $mailTmp
        fi

        case $EMAIL_SENDER in
            'sendmail')
                systemctl is-active sendmail 1>/dev/null || systemctl start sendmail
                cat $mailTmp | sendmail -t
            ;;
            'custom')
                . $(dirname $0)/sender.lib
            ;;
            *)
                systemctl is-active sendmail 1>/dev/null || systemctl start sendmail
                cat $mailTmp | sendmail -t
            ;;
        esac

        rm -f $mailTmp
    fi
}

detectReport(){
    [ ! -s "$MINER_DETAILS" ] || awk "\$10>=$MINER_PROB_REPORT_MIN {print}" $MINER_DETAILS 2>/dev/null > $MINER_REPORT_DETAILS
    [ ! -s "$MINER_REPORT_DETAILS" ] || sendEmail "$MINER_REPORT_DETAILS" "$EMAIL" detect
}

maintainerReport(){
    [ ! -s "$CLAMAV_FOR_MAINTAINER" ] || sendEmail "$CLAMAV_FOR_MAINTAINER" "$MAINTENANCE_EMAIL" clamav
    [ ! -s "$POOL_FOR_MAINTAINER" ] || sendEmail "$POOL_FOR_MAINTAINER" "$MAINTENANCE_EMAIL" pool
    [ ! -s "$SIGNATURE_FOR_MAINTAINER" ] || sendEmail "$SIGNATURE_FOR_MAINTAINER" "$MAINTENANCE_EMAIL" tool
}

main(){
    searchByToolNameInProcess
    searchByConnection
    [ -s "$MINER_DETAILS" ] || searchByTimeConsumeProcInTop

    detectReport
    maintainerReport
}

main
apiChangeMinerStatus "$MINER_PROCESSING" "$MINER_NOTE" "$MINER_SUSPEND"

exit 0
