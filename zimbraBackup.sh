#!/bin/bash
###############################################################################
# Script made by M. Rodrigo Monteiro                                          #
# Any bug, improvement or anything: mail me.                                  #
# E-mail: falecom@rodrigomonteiro.net                                         #
#                                                                             #
# Instructions:                                                               #
#                                                                             #
# The default directory for the scripts is /dados/scripts/zimbraBackup        #
#   mkdir -p /dados/scripts/zimbraBackup                                      #
#                                                                             #
# The default directory for backup is /dados/backupZimbra                     #
#   mkdir -p /dados/backupZimbra/{today,week}                                 #
#                                                                             #
# User 'zimbra' must have write permission on backup directory                #
#   chown -R zimbra.zimbra /dados/backupZimbra                                #
#                                                                             #
# Must run as root                                                            #
#                                                                             #
# Put in crontab                                                              #
#   echo '0 20 * * * root /dados/scripts/zimbraBackup/zimbraBackup.sh' \      #
#       >> /etc/crontab                                                       #
#                                                                             #
# To restore the backup (multi-line escaped command)                          #
#   zmmailbox -z -m \                                                         #
#      john@doe.com \                                                         #
#      postRestURL "//?fmt=tgz&resolve=skip" \                                #
#      john@doe.com.tar.gz                                                    #
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
# Version 0.7                                                                 #
#   Changed crontab                                                           #
#                                                                             #
###############################################################################

version=0.7

# CHANGE HERE
bzip2="/usr/bin/bzip2"
zmmailbox="/opt/zimbra/bin/zmmailbox"
zmprov="/opt/zimbra/bin/zmprov"
mysqldump="/opt/zimbra/mysql/bin/mysqldump"
mysqlsock="/opt/zimbra/db/mysql.sock"
zmlocalconfig="/opt/zimbra/bin/zmlocalconfig"
zmslapcat="/opt/zimbra/libexec/zmslapcat"
backupDir="/dados/backupZimbra"



# DO NOT CHANGE BELOW HERE

exec 1> "${backupDir}"/zimbraBackup-"$(date +%F)".log
exec 2> "${backupDir}"/zimbraBackup-"$(date +%F)".err

maxConcurrency="${1:-3}"

date="$(date +%F)"
weekday="$(date +%u)"

cd "${backupDir}" 2> /dev/null || {
	echo "Error: unable do 'cd ${backupDir}'"
	exit 1
}

# if today is Sunday, then save it in week directory, otherwise save in today directory
if [ "${weekday}" -eq 7 ] ; then
	cd "week" 2> /dev/null && backupDir="${backupDir}/week" || {
		echo "Error: unable do 'cd week'"
		exit 2
	}
else
	cd "today" 2> /dev/null && backupDir="${backupDir}/today" || {
		echo "Error: unable do 'cd today'"
		exit 3
	}
fi

echo
echo "$(date +"%F %T") - Starting erasing directory $(pwd)"
echo
rm -fv *.tar.gz *.sql *.bz2
echo
echo "$(date +"%F %T") - Finished erasing directory $(pwd)"
echo

echo "$(date +"%F %T") - Starting backup"
echo 
echo "$(date +"%F %T") - Starting MySQL backup"
"${mysqldump}" -f -S "${mysqlsock}" -u zimbra --password="$(${zmlocalconfig} -s -m nokey zimbra_mysql_password)" --all-databases --single-transaction --flush-logs > "${backupDir}"/"${date}"-mysql.sql
echo "$(date +"%F %T") - Finished MySQL backup"
echo

echo "$(date +"%F %T") - Starting OpenLDAP backup"

su - zimbra -c "${zmslapcat} ${backupDir}"
mv "${backupDir}"/ldap.bak "${backupDir}"/"${date}"-ldap.ldif
"${bzip2}" "${backupDir}"/"${date}"-ldap.ldif
rm -f "${backupDir}"/ldap.bak.*

echo "$(date +"%F %T") - Finished OpenLDAP backup"
echo

echo "$(date +"%F %T") - Starting E-mail backup"
echo

while read domain ; do
	echo "$(date +"%F %T") - Starting E-mail backup for domain ${domain}"
	echo

	while read list ; do
		echo "$(date +"%F %T") - Starting List backup for e-mail ${list}"
		"${zmprov}" -l gdl "${list}" > "${backupDir}"/"${date}"-"${list}".ldif
		"${bzip2}" "${backupDir}"/"${date}"-"${list}".ldif
		echo "$(date +"%F %T") - Finished List backup for e-mail ${list}"
		echo
	done < <("${zmprov}" -l gadl "${domain}")
	
	while read email ; do
		concurrency="$(ps aux | grep getRestURL | grep -v grep | awk '{print $21}' | sort -u | wc -l)"
		if [ "${concurrency}" -lt "${maxConcurrency}" ] ; then
			echo "$(date +"%F %T") - Starting E-mail backup for user ${email}"
			"${zmprov}" -l ga "${email}" > "${backupDir}"/"${date}"-"${email}".ldif
			"${bzip2}" "${backupDir}"/"${date}"-"${email}".ldif
			"${zmmailbox}" -z -m "${email}" getRestURL '/Calendar?fmt=ics' > "${backupDir}"/"${date}"-"${email}".ics
			"${bzip2}" "${backupDir}"/"${date}"-"${email}".ics
			"${zmmailbox}" -z -m "${email}" getRestURL '/Contacts?fmt=csv' > "${backupDir}"/"${date}"-"${email}".csv
			"${bzip2}" "${backupDir}"/"${date}"-"${email}".csv
			"${zmmailbox}" -z -m "${email}" getRestURL '/Tasks' > "${backupDir}"/"${date}"-"${email}".vcard
			"${bzip2}" "${backupDir}"/"${date}"-"${email}".vcard
			"${zmmailbox}" -z -m "${email}" getRestURL "//?fmt=tgz" > "${backupDir}"/"${date}"-"${email}".tar.gz &
			echo
		else
			until [ "${concurrency}" -lt "${maxConcurrency}" ] ; do
				concurrency="$(ps aux | grep getRestURL | grep -v grep | awk '{print $21}' | sort -u | wc -l)"
				sleep 10
			done
		fi
			
	done < <("${zmprov}" -l gaa "${domain}" | egrep -v ^"(virus\-|spam\.|ham\.|galsync)" | sort)

	echo "$(date +"%F %T") - Finished E-mail backup for domain ${domain}"
	echo

done < <("${zmprov}" -l gad | sort)

echo "$(date +"%F %T") - Finished E-mail backup"

echo
echo "$(date +"%F %T") - Finished backup"
echo


 


