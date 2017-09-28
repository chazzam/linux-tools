#!/bin/bash
# Written by Charles Moye cmoye@digium.com
# Copyright 2012 Charles Moye
#
#Licensed under the Apache License, Version 2.0 (the "License");
#you may not use this file except in compliance with the License.
#You may obtain a copy of the License at
#
#	http://www.apache.org/licenses/LICENSE-2.0
#
#Unless required by applicable law or agreed to in writing, software
#distributed under the License is distributed on an "AS IS" BASIS,
#WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#See the License for the specific language governing permissions and
#limitations under the License.

# fsck-boot.sh
# Find and fsck any ext2/ext3/ext4 volumes. Supports lvm.
# Requires lvm2, e2fsprogs, file

#set -x;
echo "Giving time for system to finish bringing up devices...";
sleep 10
SUDO=$(which sudo);
# Enable using LVM Volumes
${SUDO} /usr/local/sbin/vgchange -ay
sleep 2
# Build list of LVM and standard volumes
SDX_VOLS="$(${SUDO} fdisk -l /dev/sd* 2>&1 | grep Linux|grep -v LVM|awk '{print $1; }')";
LVM_VOLS="$(${SUDO} lvdisplay | grep 'LV Name'|awk '{print $3; }')";

echo -e "\n\n\nFound these potential volumes: ";
echo $SDX_VOLS $LVM_VOLS;
echo;

for vol in $SDX_VOLS $LVM_VOLS;
do
	# Determine the type of the file system.
	TYPE="$(${SUDO} file -sL $vol | sed -e 's/.*\(swap\|ext.\).*/\1/')";
	# Don't run the check on the swap file system.
	if [ "${TYPE}" != "swap" ] && [ "${TYPE}" != "" ]; then
		# run the file system check and alert the user.
		echo -e "\n\n\nRunning fsck on ${TYPE} filesystem at ${vol}";
		${SUDO} e2fsck -pfc $vol;
	else
		echo -e "\n\n\nNot checking ${TYPE} filesystem at ${vol}";
	fi;
done;
echo -e "\n\n\nPress Enter to reboot."
read y
${SUDO} reboot;
