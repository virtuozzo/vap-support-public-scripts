#!/bin/bash

mkdir /tmp/vz-template-upgrade &>/dev/null;

err(){ echo -e "\\033[1;31m$@\\033[0;39m"; exit 255; } ;
success(){ echo -e "\\033[1;32m$@\\033[0;39m"; exit 0; } ;
g_i(){ echo -e "\\033[1;32m$@\\033[0;39m"; } ;
c_i(){ echo -e "\\033[1;34m$@\\033[0;39m"; } ;
y_i(){ echo -e "\\033[1;33m$@\\033[0;39m"; } ;
r_i(){ echo -e "\\033[1;31m$@\\033[0;39m"; } ;
w_i(){ echo -e "\\033[1;37m$@\\033[0;39m"; } ;

TMPL_UPGRADE_PERIOD=4;
DRY_RUN=0;
PP_PERIOD=
PP_DRYRUN=
PP_LITE=
LITE_MODE=

TIMESTAMP_VALUE=

while getopts p:d:l: option
do
case "${option}"
in
        p) PP_PERIOD=$OPTARG;;
        d) PP_DRYRUN=$OPTARG;;
	l) PP_LITE=$OPTARG;;
esac
done

PP_PERIOD=1;
PP_DRYRUN=0;

[[ "$PP_PERIOD" =~ ^[0-9]+$ ]] || err "Specified period is not numeric"
[[ "$PP_DRYRUN" =~ ^[0-9]+$ ]] || err "Specified dryrun mode is not numeric"
[[ "$PP_LITE" =~ ^[0-9]+$ ]] || err "Specified lite mode is not numeric"
[[ "$PP_DRYRUN" == '0' ]] || [[ "$PP_DRYRUN" == '1' ]] || err "Wrong parameter for Dry-run mode (0 or 1)"
[[ "$PP_LITE" == '0' ]] || [[ "$PP_LITE" == '1' ]] || err "Wrong parameter for Lite mode (0 or 1)"
[ -n $PP_PERIOD ] && [ $PP_PERIOD -ge 1 ] && TMPL_UPGRADE_PERIOD="${PP_PERIOD}" || err "Specified period shoud be at least 1 day";
[ -n $PP_LITE ] && LITE_MODE="${PP_LITE}";
[ -n $PP_DRYRUN ] && DRY_RUN="${PP_DRYRUN}";

TMPL_UPGRADE_PERIOD_SEC=$(($TMPL_UPGRADE_PERIOD*60*60*24));

CURRENT_TEMPLATES=(
alpine-3.x-x86_64 \
centos-7-x86_64 \
almalinux-8-x86_64 \
almalinux-9-x86_64 \
centos-minimal-7-x86_64 \
debian-12.0-x86_64 \
debian-11.0-x86_64 \
debian-10.0-x86_64 \
debian-9.0-x86_64 \
ubuntu-16.04-x86_64 \
ubuntu-18.04-x86_64 \
ubuntu-20.04-x86_64 \
ubuntu-22.04-x86_64 \
vzlinux-8-x86_64
#debian-8.0-x86_64
);

# centos-8.stream-x86_64 \
# debian-8.0-x86_64 \
# debian-8.0-x86_64-minimal \

# New templates for infra:

CURRENT_TEMPLATES_LITE=(
centos-7-x86_64 \
centos-jelastic-7-x86_64 \
centos-minimal-7-x86_64 \
);

# Old templates:

OLD_TEMPLATES=(
busybox-jelastic-multiverse-x86_64 \
centos-5-x86_64 \
debian-6.0-x86_64 \
fedora-17-x86_64 \
fedora-18-x86_64 \
fedora-19-x86_64 \
fedora-20-x86_64 \
fedora-21-x86_64 \
fedora-22-x86_64 \
fedora-23-x86_64 \
redhat-el5-x86_64 \
redhat-el6-x86_64 \
redhat-el7-x86_64 \
suse-es11-x86_64 \
suse-12.1-x86_64 \
suse-12.2-x86_64 \
suse-12.3-x86_64 \
ubuntu-10.04-x86_64 \
ubuntu-13.10-x86_64 \
ubuntu-14.10-x86_64 \
ubuntu-15.04-x86_64 \
ubuntu-15.10-x86_64 \
);

if_tmpl_installed(){
	vzpkg list -O 2>/dev/null | grep -q "$1[[:blank:]]" || return 255;	
}

get_tmpl_date(){
	TMPL_DATE=
	TMPL_DATE=$(vzpkg list -O 2>/dev/null | grep "$1[[:blank:]]" | awk {' print $2 " " $3 '});
	[[ -z $TMPL_DATE ]] && return 255;
	date_to_timestamp $TMPL_DATE;
	return 0;
}

is_actual(){
	ACT_STAMP=$(date +%s);
	get_tmpl_date $1;
	[ ! -z $TMPL_STAMP ] || err "Coun't get timestamp for $1 template";
	DIFF_STAMPS=$(echo "$ACT_STAMP-$TMPL_STAMP" | bc -l);
	[ $DIFF_STAMPS -gt $TMPL_UPGRADE_PERIOD_SEC ] && return 255 || return 0;
}

date_to_timestamp() {
	if [ -z "$1" ] || [ -z "$2" ]; then
# 		y_i "Warning: empty date parameter passed, assuming the initial UNIX datetime '1970-01-01 00:00:00 UTC'"
		TMPL_STAMP=1
	else
		TMPL_STAMP=$(date -d "$1 $2" +%s)
	fi
	return 0
}

install_template(){
	/usr/bin/yum install -y $1-ez &>/dev/null || return 255;
	vzpkg clean $1 &>/dev/null || return 255;
	/usr/sbin/vzpkg update cache $1 &>/dev/null || return 255;
	return 0
}

upgrade_template(){
	/usr/bin/yum upgrade -y $1-ez &>/tmp/vz-template-upgrade/$TMPL_NAME.log || return 255;
	vzpkg clean $1 &>/dev/null || return 255;
	/usr/sbin/vzpkg update metadata $1 &>>/tmp/vz-template-upgrade/$TMPL_NAME.log || return 255;
	/usr/sbin/vzpkg update cache $1 &>>/tmp/vz-template-upgrade/$TMPL_NAME.log || return 255;
	return 0;
}

remove_template(){
	shopt -s nullglob
	shopt -s dotglob

	/usr/sbin/vzpkg remove cache $1 &>/dev/null || return 255;
	/usr/bin/yum remove -y $1-ez &>/dev/null || return 255;
	rm -rf /vz/template/cache/$1.* &>/dev/null

	shopt -u nullglob
	shopt -u dotglob
}

fix_urlmaps(){
	w_i "$(date -u): Fixing URL maps...";
	grep -q "^\$SW_SERVER" /etc/vztt/url.map || \
	 echo "\$SW_SERVER    http://vzdownload.swsoft.com" >> /etc/vztt/url.map
	grep -q "^\$CE_SERVER" /etc/vztt/url.map || \
	 echo "\$CE_SERVER    http://mirror.centos.org" >> /etc/vztt/url.map
	grep -q "^\$SUSE_SERVER" /etc/vztt/url.map || \
	 echo "\$SUSE_SERVER/pub/opensuse      http://download.opensuse.org" >> /etc/vztt/url.map
	grep -q "^\$SUSE2_SERVER" /etc/vztt/url.map || \
	 echo "\$SUSE2_SERVER    ftp://ftp.suse.com" >> /etc/vztt/url.map
	grep -q "^\$DEB_SERVER" /etc/vztt/url.map || \
	 echo "\$DEB_SERVER    ftp://ftp.de.debian.org" >> /etc/vztt/url.map
	grep -q "^\$UBU_SERVER" /etc/vztt/url.map || \
	 echo "\$UBU_SERVER    http://archive.ubuntu.com" >> /etc/vztt/url.map
	grep -q "^\$JS_SERVER" /etc/vztt/url.map || \ 
	 echo "\$JS_SERVER    http://repository.jelastic.com" >> /etc/vztt/url.map
}

process_new_templates(){
	w_i "$(date -u): Upgrading templates...";	
	for TMPL_NAME in "${CURRENT_TEMPLATES[@]}"; do
	if_tmpl_installed $TMPL_NAME || \
	{ r_i "Template $TMPL_NAME is not installed..."; \
		  install_template $TMPL_NAME || err "Can't install $TMPL_NAME template..."; \
		  if_tmpl_installed $TMPL_NAME || \
		  err "Template $TMPL_NAME won't be installed!" 
	};
	is_actual $TMPL_NAME && g_i "Template $TMPL_NAME is up to date!" || \
	{ c_i "Upgrading template $TMPL_NAME [LOG: /tmp/vz-template-upgrade/$TMPL_NAME.log]"; \
	upgrade_template $TMPL_NAME || r_i "Failed to upgrade template $TMPL_NAME"; \
	};
	is_actual $TMPL_NAME || r_i "Template $TMPL_NAME seems was not upgraded...";
	done

}

process_new_templates_lite(){
        w_i "$(date -u): Upgrading templates...";
        for TMPL_NAME in "${CURRENT_TEMPLATES_LITE[@]}"; do
        if_tmpl_installed $TMPL_NAME || \
        { r_i "Template $TMPL_NAME is not installed..."; \
                  install_template $TMPL_NAME || err "Can't install $TMPL_NAME template..."; \
                  if_tmpl_installed $TMPL_NAME || \
                  err "Template $TMPL_NAME won't be installed!"
        };
        is_actual $TMPL_NAME && g_i "Template $TMPL_NAME is up to date!" || \
        { c_i "Upgrading template $TMPL_NAME [LOG: /tmp/vz-template-upgrade/$TMPL_NAME.log]"; \
        upgrade_template $TMPL_NAME || r_i "Failed to upgrade template $TMPL_NAME"; \
        };
        is_actual $TMPL_NAME || r_i "Template $TMPL_NAME seems was not upgraded...";
        done

}

process_old_templates(){
	w_i "$(date -u): Removing deprecated templates...";
	for TMPL_NAME in "${OLD_TEMPLATES[@]}"; do
		if_tmpl_installed $TMPL_NAME && { y_i "Removing obsolete template $TMPL_NAME"; remove_template $TMPL_NAME; } ;
	done
}

new_templates_info(){
        w_i "$(date -u): Checking actual templates...";     
        for TMPL_NAME in "${CURRENT_TEMPLATES[@]}"; do
        if_tmpl_installed $TMPL_NAME && { is_actual $TMPL_NAME && g_i "Template $TMPL_NAME is up to date!" || r_i "Template $TMPL_NAME seems to be outdated!"; } || r_i "Template $TMPL_NAME is not installed!";
        done
	return 0;
}

old_templates_info(){
        w_i "$(date -u): Cheking deprecated templates...";
        for TMPL_NAME in "${OLD_TEMPLATES[@]}"; do
        if_tmpl_installed $TMPL_NAME && w_i "Template $TMPL_NAME supposed to be deleted" || c_i "Template $TMPL_NAME was already deleted...";
	done
	return 0;
}

deb_fix(){
	w_i "$(date -u): Fixing deprecated repos for Debian 9 templates...";
	grep -q '$DEB_ARCHIVE  http://archive.debian.org' /etc/vztt/url.map || echo '$DEB_ARCHIVE  http://archive.debian.org' >> /etc/vztt/url.map;
	ls -l /vz/template/debian/9.0/x86_64/config/os/default/repositories &>/dev/null && {
	echo '$DEB_ARCHIVE/debian stretch main contrib non-free' > /vz/template/debian/9.0/x86_64/config/os/default/repositories ;
	echo '$DEB_ARCHIVE/debian stretch-proposed-updates main contrib non-free' >> /vz/template/debian/9.0/x86_64/config/os/default/repositories ;
	echo '$DEB_ARCHIVE/debian-security stretch/updates main contrib non-free' >> /vz/template/debian/9.0/x86_64/config/os/default/repositories ;
	} ;
#	ls -l /vz/template/debian/8.0/x86_64/config/os/default/repositories &>/dev/null && {
#	echo '$DEB_ARCHIVE/debian jessie main contrib non-free' > /vz/template/debian/8.0/x86_64/config/os/default/repositories ;
#	echo '$DEB_ARCHIVE/debian jessie main contrib non-free' >> /vz/template/debian/8.0/x86_64/config/os/default/repositories ;
#	echo '$DEB_ARCHIVE/debian-security jessie/updates main contrib non-free' >> /vz/template/debian/8.0/x86_64/config/os/default/repositories ;
#	} ;
}

[ $DRY_RUN == '1' ] && { new_templates_info; old_templates_info; };
[ $DRY_RUN == '0' ] && { [ $LITE_MODE == '0' ] && deb_fix; } ;
[ $DRY_RUN == '0' ] && fix_urlmaps;
[ $DRY_RUN == '0' ] && { [ $LITE_MODE == '0' ] && process_new_templates || process_new_templates_lite; } ;
[ $DRY_RUN == '0' ] && process_old_templates;
[ $DRY_RUN == '0' ] && c_i "Processed VZ templates successfully!";

exit 0;
