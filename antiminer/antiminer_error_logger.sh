#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/root/bin:$PATH

# Include config file
. $(dirname $0)/antiminer.sh.conf || { errorLog "No configuration file found"; exit 1; }

logFile=/tmp/antiminer_error.log
hostnameDomain=$(hostname -d)
from="$PLATFORM_NAME <$(hostname -s)@${hostnameDomain:-$(hostname -s)}>"
to="$MAINTENANCE_EMAIL"
subject="[MAINTENANCE] Antiminer script has errors on $(hostname -s) ($(date +'%F %H:%M UTC'))"

if [ -s $logFile ]; then
    mailTmp=$(mktemp)
    echo "From: $from" > $mailTmp
    echo "To: $to" >> $mailTmp
    echo "Subject: $subject" >> $mailTmp
    echo >> $mailTmp
    echo -e "Errors:\n" >> $mailTmp
    cat $logFile >> $mailTmp

    case $EMAIL_SENDER in
        'sendmail')
            which sendmail 2>/dev/null || { echo "Error: can't find 'sendmail'"; exit 1; }
            systemctl is-active sendmail 1>/dev/null || systemctl start sendmail
            cat $mailTmp | sendmail -t
        ;;
        'custom')
            . $(dirname $0)/sender.lib
        ;;
        *)
            which sendmail 2>/dev/null || { echo "Error: can't find 'sendmail'"; exit 1; }
            systemctl is-active sendmail 1>/dev/null || systemctl start sendmail
            cat $mailTmp | sendmail -t
        ;;
    esac

    rm -f $mailTmp $logFile 2>/dev/null
fi

exit 0
