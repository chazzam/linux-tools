#!/bin/sh

. /srv/tftp/bin/libdebian.sh


echo "Updating Ubuntu..."
DISTRO="$DISTRO_UBUNTU"
DISTRO_TITLE="$DISTRO_TITLE_UBUNTU"
MIRROR_BASE="$MIRROR_BASE_UBUNTU"
DEB_RELEASES="$DEB_RELEASE_UBUNTU";

update_variables;
DEB_RELEASES="$(get_releases)"
create_directories;
download_netboot;
write_bootscreens;

echo "Ubuntu: Done";

echo "Updating Debian..."
DISTRO="$DISTRO_DEBIAN"
DISTRO_TITLE="$DISTRO_TITLE_DEBIAN"
MIRROR_BASE="$MIRROR_BASE_DEBIAN"
DEB_RELEASES="$DEB_RELEASE_DEBIAN";

update_variables;
DEB_RELEASES="$(get_releases)"
create_directories;
download_netboot;
write_bootscreens;

echo "Debian: Done";

