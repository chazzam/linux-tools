#!/bin/bash
# remaster switchvox ISO

# Needs: mtools, syslinux, parted, dosfstools, isomd5sum
set -x;
if [ $(id -u) -ne 0 ]; then
  echo "You must be root to run this.";
  exit 1;
fi;

# $1 - switchvox ISO image
# $2 - path to thumbdrive device partition
# $3 - site to build for, default to PALCO, also have HSV and CUSTOMERS
SWITCHVOX_ISO="${1}";
USB_STICK_DEVICE="${2}";
SITE="${3}";
# TODO: swap order of SITE and USB_STICK_DEVICE parameters
# TODO: add support for multiple device parameters and process each of them.
# TODO: optionally, search system for unmounted /dev/sd*1's and process all of those.

CUSTOMERS="CUSTOMERS";
PALCO="PALCO";
HSV="HSV";

if [ "" = "${SWITCHVOX_ISO}" ] || [ "" = "${USB_STICK_DEVICE}" ]; then
	echo "Must specify /path/to/switchvox/ISO and path/to/USB/device.";
	exit 2;
fi;
if [ "" = "${SITE}" ]; then
	SITE="PALCO";
fi;
if [ "${PALCO}" != "${SITE}" ] && [ "${HSV}" != "${SITE}" ] && [ "${CUSTOMERS}" != "${SITE}" ]; then
	echo -e "Must specify a valid site.\nTry: ${PALCO}, ${CUSTOMERS}, or ${HSV}";
	exit 3;
fi;

DRIVE_MOUNT="$(mktemp -d /tmp/usbdev.XXXXXX)";
INITRD_DIR="/tmp/old-init";
INITRD_IMG="initrd.img";
ISO_DIR="LiveOS";
#ISO_DIR="/";
DIR="$(pwd)";
KICKSTART="ks.cfg";
SYSLINUX_CFG="syslinux/syslinux.cfg";

COPY="cp -ap"
if [ "$(which rsync)" != "" ]; then
	COPY="$(which rsync) -LPpr";
fi;

## Prepare thumb drive
# Call livecd to disk script
bash livecd-iso-to-disk.sh --non-interactive --reset-mbr --format ${SWITCHVOX_ISO} ${USB_STICK_DEVICE};
if [ $? != 0 ]; then
	echo "Error occured in livecd script";
	exit 9;
fi;

# mount thumb drive
mkdir -p ${DRIVE_MOUNT};
mount ${USB_STICK_DEVICE} ${DRIVE_MOUNT};

## Copy CD ISO to thumb drive LiveOS directory
# check if rsync is available
echo "Copying ISO to thumbdrive...";
${COPY} ${SWITCHVOX_ISO} ${DRIVE_MOUNT}/${ISO_DIR};

## Prepare to create boot environment
# extract initrd image to /tmp/old-init/ to get at the kickstart file
echo "Pulling information from initrd image...";
rm -rf ${INITRD_DIR} /tmp/initrd.gz ${INITRD_DIR}/new-initrd.cpio.gz 2>/dev/null;
mkdir -p ${INITRD_DIR};
cd ${INITRD_DIR};
#${COPY} ${DRIVE_MOUNT}/syslinux/${INITRD_IMG} /tmp/initrd.gz;
#echo "Flushing buffers"; sync;
echo "Extracting initrd image";
# Try to ungzip it first, if that fails try just extracting with cpio
gzip -dc "${DRIVE_MOUNT}/syslinux/${INITRD_IMG}" 2>/dev/null | cpio -iud 2>/dev/null;
if [ "$?" != "0" ]; then
  cpio -iud < "${DRIVE_MOUNT}/syslinux/${INITRD_IMG}";
  if [ "$?" != "0" ]; then
    echo "failed to extract initrd image to pull out kickstart file";
    exit 9;
  fi;
fi;
echo "Flushing buffers to ensure ISO and initrd are fully written before continuing";
echo "This will probably take a while...";
sync;
${COPY} ${KICKSTART} ${DRIVE_MOUNT}/${ISO_DIR}
echo "Finished initrd information collection processes";

## Modify boot environment
echo "updating kickstart file";
# modify ks.cfg file
#~ cd ${INITRD_DIR};
cd ${DRIVE_MOUNT}/${ISO_DIR};
if [ ! -f ${KICKSTART} -o ! -w ${KICKSTART} ]; then
  echo "kickstart file either doesn't exist or isn't writable";
  exit 9;
fi;
# Adjust so it will support booting from USB instead of CDROM
sed -i -e "s#cdrom#harddrive --partition=sdb1 --dir=${ISO_DIR}#;" ${KICKSTART};
# set the timezone
if [ "${CUSTOMERS}" = "${SITE}" ] || [ "${PALCO}" = "${SITE}" ]; then
	sed -i -e 's%#timezone%timezone%;s%America/.*%--utc America/New_York%;' ${KICKSTART};
else
	sed -i -e 's%#timezone%timezone%;s%America/.*%--utc America/Chicago%;' ${KICKSTART};
fi;
# Adjust partitioning to not delete or use the thumbdrive and to handle new disks
sed -i -e 's/^clearpart/zerombr yes\nclearpart/' ${KICKSTART};
sed -i -e 's/^clearpart /ignoredisk --drives=sdb\nclearpart --drives=sda --initlabel /;' ${KICKSTART};
sed -i -e '/bootloader/{s/$/ --driveorder=sda,hda/;};' ${KICKSTART};

if [ "${PALCO}" = "${SITE}" ]; then
	# Add poweroff when done
	sed -i -e 's/%packages/poweroff\n%packages/' ${KICKSTART};
fi;

if [ "${HSV}" = "${SITE}" ]; then
	# Change root password
	#$1$29Mvb2vy$NSbVmLoEDA08excQu6VJj/
	#sed -i -e 's/rootpw --iscrypted .*/rootpw D!G!UM8sw1tchv0xP*X/;' ${KICKSTART};
	sed -i -e 's/rootpw --iscrypted .*/rootpw blah/;' ${KICKSTART};
	# Re-enable sshd
	sed -i -e 's/sshd off/sshd on/;' ${KICKSTART};
	# Disable deleting the root password
	sed -i -e 's/perl -i -npe .*//;' ${KICKSTART};
	# change poweroff to restart
	sed -i -e 's/poweroff/restart/;' ${KICKSTART};
fi;

echo "Kickstart file configured, adjusting boot configuration";
# Modify syslinux.cfg as needed.
#sed -i -e 's#ks#method=hd:sdb1:/LiveOS ks#;s#ks=[^ ]*#ks=hd:sdb1:/LiveOS/ks.cfg#;' ${DRIVE_MOUNT}/${SYSLINUX_CFG};
sed -i -e 's#ks#method=hd:sdb1:/LiveOS ks#;' ${DRIVE_MOUNT}/${SYSLINUX_CFG};
sed -i -e 's#600#100#;' ${DRIVE_MOUNT}/${SYSLINUX_CFG};

# Make sure the disc is synced up before continuing.
echo "waiting on devices to synchronize writes";
sync;

## Replace initrd environment
# repack initrd image and put it on thumbdrive
echo "Packaging boot environment";
${COPY} ${KICKSTART} ${INITRD_DIR}/;
cd ${INITRD_DIR};
find ./ | cpio -H newc -o > /tmp/new-initrd.cpio;sync;
cd /tmp/;
gzip -q new-initrd.cpio;sync;
${COPY} new-initrd.cpio.gz ${DRIVE_MOUNT}/syslinux/${INITRD_IMG};sync;
# Clean up image
#rm -rf initrd ${INITRD_DIR} 2>/dev/null;

## Wrap up
# Unmount thumb drive
echo "Unmounting thumb drive on ${USB_STICK_DEVICE}...";
cd ${DIR};
umount ${DRIVE_MOUNT};
echo "Setup Complete!";
echo "You may now remove the thumbdrive on ${USB_STICK_DEVICE} from the system";
