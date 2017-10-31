#!/bin/bash

###############################################################################
# Script made by M. Rodrigo Monteiro                                          #
# Any bug or request:                                                         #
#   E-mail: falecom@rodrigomonteiro.net                                       #
#   https://github.com/mrodrigom/                                             #
# Use at your own risk                                                        #
# Tested on CentOS Linux release 7.2 64 bits                                  #
#                                                                             #
# Instructions:                                                               #
# yum install epel-release                                                    #
# yum install parallel gawk bzip2 iproute                                     #
#                                                                             #
# Script to backup Zimbra (MySQL + OpenLDAP + Mail + Contacts + Calendar +    #
#   Tasks + Lists + User Attributes)                                          #
# The MySQL and OpenLDAP is for disaster/recover (full server) while the rest #
#   individual.                                                               #
#                                                                             #
# The default directory for the scripts is /opt/scripts/zimbraBackup          #
#   mkdir -p /opt/scripts/zimbraBackup/                                       #
#                                                                             #
# The default directory for backup is /opt/backupZimbra                       #
#   mkdir -p /opt/backupZimbra/                                               #
#                                                                             #
# Mailbox                                                                     #
#   Sun = full backup                                                         #
#   Mon-Sat = incremental backup                                              #
# MySQL, OpenLDAP, Contacts, Calendar, Tasks and Lists                        #
#   Always full                                                               #
#                                                                             #
# User 'zimbra' must have write permission on backup directory                #
#   chown -R zimbra.zimbra /opt/backupZimbra                                  #
#                                                                             #
# Must run script as root                                                     #
# chmod 700 /opt/scripts/zimbraBackup/zimbraBackup.sh                         #
#                                                                             #
# Put in crontab (multi-line escaped command)                                 #
#   echo '0 0 * * * root /opt/scripts/zimbraBackup/zimbraBackup.sh' \         #
#       >> /etc/crontab                                                       #
#                                                                             #
# The concurrency (mail backups in parallel) is 6                             #
#                                                                             #
# To restore the mail backup (multi-line escaped command)                     #
#   zmmailbox -z -m \                                                         #
#      john@doe.com \                                                         #
#      postRestURL "//?fmt=tgz&resolve=skip" \                                #
#      john@doe.com.tgz                                                       #
#                                                                             #
# Version 0.1 (11/01/2012)                                                    #
#   Begin                                                                     #
# Version 0.2 (30/01/2012)                                                    #
#   Add the function to save the today backup and the week backup             #
#   The week backup is every Sunday and it's not overwritten by today backup  #
# Version 0.3 (22/04/2014)                                                    #
#   Add the command to create the directory's structure                       #
#   Don't backup the account virus-*                                          #
# Version 0.4 (26/06/2014)                                                    #
#   Add command to restore backup                                             #
# Version 0.5 (03/10/2014)                                                    #
#   Add lists and user ldiff                                                  #
#   Add concurrency (default 3)                                               #
# Version 0.6 (06/10/2014)                                                    #
#   Add contact                                                               #
#   Add calendar                                                              #
#   Add tasks                                                                 #
# Version 0.7 (06/10/2014)                                                    #
#   Changed crontab                                                           #
# Version 0.8 (13/10/2014)                                                    #
#   Added project to github                                                   #
#   Changed the default directory                                             #
# Version 1.0 (30/10/2017)                                                    #
#   Added incremental backup                                                  #
#   Using "parallel" to handle multiples backups at the same time             #
#   Changed default maxConcurrency to 6                                       #
###############################################################################
#set -x

version=1.0

#put you Zimbra ip here
ipZimbra="XXX.XXX.XXX.XXX"

bzip2="/usr/bin/bzip2"
awk="/bin/awk"
zmmailbox="/opt/zimbra/bin/zmmailbox"
zmprov="/opt/zimbra/bin/zmprov"
mysqldump="/opt/zimbra/mysql/bin/mysqldump"
mysqlsock="/opt/zimbra/db/mysql.sock"
zmlocalconfig="/opt/zimbra/bin/zmlocalconfig"
zmslapcat="/opt/zimbra/libexec/zmslapcat"
parallel="/bin/parallel"
backupDir="/opt/backupZimbra"
allEmails="${backupDir}/allEmails.txt"
allLists="${backupDir}/allLists.txt"
backupParallel="${backupDir}/backupParallel.txt"
date="$(date +%F)"
weekday="$(date +%u)"
yesterday="$(date --date="yesterday" +%m"/"%d"/"%Y)"
weekAgo="$(date --date="1 week ago" +%m"/"%d"/"%Y)"


# DO NOT CHANGE BELOW HERE

#if you have multiple zimbra servers, run only on the one you choose
ip ad s | grep "${ipZimbra}" > /dev/null 2>&1
if [[  "$?" != 0 ]]; then
	exit 1
fi

unalias rm > /dev/null 2>&1
exec 1> "${backupDir}"/zimbraBackup-"$(date +%F)".log
exec 2> "${backupDir}"/zimbraBackup-"$(date +%F)".err

if [ "$#" -gt 1 -o "${1}" = "-h" -o "${1}" = "--help" ] ; then
	echo "Usage: $0 [concurrency]"
	exit 2
fi

maxConcurrency="${1:-6}"

cd "${backupDir}" 2> /dev/null || {
	echo "Error: unable do 'cd ${backupDir}'"
	exit 3
}

rm "${allEmails}" "${allLists}" "${backupParallel}" 2> /dev/null
rm "${date}"-* 2> /dev/null

echo
echo "$(date +"%F %T") - Starting backup"
echo

if [ "${weekday}" -eq 7 ] ; then
	echo "$(date +"%F %T") - Starting erasing directory $(pwd)"
	rm -fv *.tgz *.bz2 *.sql 2> /dev/null
	echo "$(date +"%F %T") - Finished erasing directory $(pwd)"
fi

echo "$(date +"%F %T") - Starting MySQL backup"
"${mysqldump}" -f -S "${mysqlsock}" -u zimbra --password="$(${zmlocalconfig} -s -m nokey zimbra_mysql_password)" --all-databases --single-transaction --flush-logs > "${backupDir}/${date}-mysql.sql"
echo "$(date +"%F %T") - Finished MySQL backup"
echo

echo "$(date +"%F %T") - Starting OpenLDAP backup"

su - zimbra -c "${zmslapcat} ${backupDir}"
mv "${backupDir}/ldap.bak" "${backupDir}/${date}-ldap.ldif"
"${bzip2}" "${backupDir}/${date}-ldap.ldif"
rm -f "${backupDir}"/ldap.bak.*

echo "$(date +"%F %T") - Finished OpenLDAP backup"
echo

touch "${backupParallel}" "${allLists}"

echo "$(date +"%F %T") - Starting scheduling listing users and lists"
while read domain ; do
	while read email ; do
		echo "${email}" >> "${allEmails}"
	done < <("${zmprov}" -l gaa "${domain}" | egrep -v ^'(virus\-|spam\.|ham\.|galsync)' | sort)

	while read list ; do
		echo "${list}" >> "${allLists}"
	done < <("${zmprov}" -l gadl "${domain}")
done < <("${zmprov}" -l gad | sort)	
echo "$(date +"%F %T") - Finished scheduling listing users and lists"

#attributes
"${awk}" -v arquivo="${backupDir}/${date}-" -v zmprov="${zmprov}" '{print zmprov " -l ga " $1 " > " arquivo $1 ".ldif"}' "${allEmails}" >> "${backupParallel}"
"${awk}" -v bzip2="${bzip2}" -v arquivo="${backupDir}/${date}-" '{print bzip2 " " arquivo $1 ".ldif"}' "${allEmails}" >> "${backupParallel}"

#calendar
"${awk}" -v arquivo="${backupDir}/${date}-" -v zmmailbox="${zmmailbox}" '{print zmmailbox " -z -m " $1 " getRestURL \"/Calendar?fmt=ics\" > " arquivo $1 ".ics"}' "${allEmails}" >> "${backupParallel}"
"${awk}" -v bzip2="${bzip2}" -v arquivo="${backupDir}/${date}-" '{print bzip2 " " arquivo $1 ".ics"}' "${allEmails}" >> "${backupParallel}"

#contacts
"${awk}" -v arquivo="${backupDir}/${date}-" -v zmmailbox="${zmmailbox}" '{print zmmailbox " -z -m " $1 " getRestURL \"/Contacts?fmt=csv\" > " arquivo $1 ".csv"}' "${allEmails}" >> "${backupParallel}"
"${awk}" -v bzip2="${bzip2}" -v arquivo="${backupDir}/${date}-" '{print bzip2 " " arquivo $1 ".csv"}' "${allEmails}" >> "${backupParallel}"

#tasks
"${awk}" -v arquivo="${backupDir}/${date}-" -v zmmailbox="${zmmailbox}" '{print zmmailbox " -z -m " $1 " getRestURL \"/Tasks\" > " arquivo $1 ".vcard"}' "${allEmails}" >> "${backupParallel}"
"${awk}" -v bzip2="${bzip2}" -v arquivo="${backupDir}/${date}-" '{print bzip2 " " arquivo $1 ".vcard"}' "${allEmails}" >> "${backupParallel}"

#distribution lists
"${awk}" -v arquivo="${backupDir}/${date}-" -v zmprov="${zmprov}" '{print zmprov " -l gdl " $1 " > " arquivo $1 ".ldif"}' "${allLists}" >> "${backupParallel}"
"${awk}" -v bzip2="${bzip2}" -v arquivo="${backupDir}/${date}-" '{print bzip2 " " arquivo $1 ".ldif"}' "${allLists}" >> "${backupParallel}"

echo "$(date +"%F %T") - Starting scheduling e-mail"

# if today is Sunday, then do clear directory and do full backup. If not, do incremental backup
if [ "${weekday}" -eq 7 ] ; then
	rm "${weekAgo}"-* 2> /dev/null
	"${awk}" -v arquivo="${backupDir}/${date}-full-" -v zmmailbox="${zmmailbox}" '{print zmmailbox " -z -m " $1 " getRestURL \"//?fmt=tgz\" > " arquivo $1 ".tgz"}' "${allEmails}" >> "${backupParallel}"
else
	"${awk}" -v arquivo="${backupDir}/${date}-inc-" -v zmmailbox="${zmmailbox}" -v yesterday="${yesterday}" '{print zmmailbox " -z -m " $1 " getRestURL \"//?fmt=tgz&query=date:" yesterday "\" > " arquivo $1 ".tgz"}' "${allEmails}" >> "${backupParallel}"
fi

echo "$(date +"%F %T") - Finished scheduling e-mail"


echo "$(date +"%F %T") - Starting backuping e-mail with ${maxConcurrency} process in parallel"

"${parallel}" --no-notice --jobs "${maxConcurrency}" < "${backupParallel}"

echo "$(date +"%F %T") - Finished backuping e-mail with ${maxConcurrency} process in parallel"

echo
echo "$(date +"%F %T") - Finished backup"
echo

