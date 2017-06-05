#!/bin/sh
TFTP_ROOT=/srv/tftp

DISTRO_UBUNTU="ubuntu"
DISTRO_DEBIAN="debian"
DISTRO_TITLE="Ubuntu"
DISTRO_TITLE_UBUNTU="Ubuntu"
DISTRO_TITLE_DEBIAN="Debian"
MIRROR_BASE_UBUNTU="us.archive.ubuntu.com"
MIRROR_BASE_DEBIAN="ftp.us.debian.org"
DEB_RELEASES_UBUNTU="precise trusty xenial";
DEB_RELEASES_DEBIAN="jessie stretch sid wheezy";
DEB_ARCHES="i386 amd64"

update_variables() {
  DEB_ROOT="$TFTP_ROOT/${DISTRO}-installer";
  DEB_MIRROR="http://${MIRROR_BASE}/${DISTRO}";
  DEB_BOOTSCREENS="$TFTP_ROOT/boot-screens/${DISTRO}.txt";
}

get_releases() {
  echo "$(curl -s ${DEB_MIRROR}/dists/|
    grep -Eo '[hH][rR][eE][fF]="[^"]*/"'|
    grep -Ev 'updates|backports|stable|testing|experimental|proposed|security|devel|http|freebsd|rc-buggy|[dD]ebian|ubuntu|\.\.'|
    tr -d '"/'|
    cut -d= -f2)"
}

create_directories() {
  # Create the directories desired
  local rel;
  local arch;
  for rel in $DEB_RELEASES; do
    [ -d "$DEB_ROOT/$rel" ] || mkdir -p "$DEB_ROOT/$rel";
    for arch in $DEB_ARCHES; do
      [ -d "$DEB_ROOT/$rel/$arch" ] || mkdir -p "$DEB_ROOT/$rel/$arch";
    done;
  done;
}

download_netboot() {
  # Download the netboot files
  local rel;
  local arch;
  for rel in $(ls $DEB_ROOT); do
    [ -d "${DEB_ROOT%%/}/$rel" ] || continue;
    #[ "$rel" = "squeeze" ] && continue;
    for arch in $(ls $DEB_ROOT/$rel); do
      local path_arch="$DEB_MIRROR/dists/$rel/main/installer-$arch/current/images/netboot/${DISTRO}-installer/$arch";
      echo "Downloading files for $rel $arch";
      (
        cd $DEB_ROOT/$rel/$arch;
        wget -nv -N --random-wait "$path_arch/linux" "$path_arch/initrd.gz";
      )
    done;
  done;
}

write_bootscreens() {
  local rel;
  local arch;
  local dir_bootscreen="$(dirname $DEB_BOOTSCREENS)";
  echo "Writing pxelinux bootmenu: $DEB_BOOTSCREENS";
  # create directory if needed
  [ -d "$dir_bootscreen" ] || mkdir -p "$dir_bootscreen"
  [ -f "$DEB_BOOTSCREENS" ] && mv $DEB_BOOTSCREENS $DEB_BOOTSCREENS.bak
  ( cat <<EOH
MENU TITLE ${DISTRO_TITLE} Menu

menu color title        * #FFFFFFFF *
menu color border       * #00000000 #00000000 none
menu color sel          * #ffffffff #76a1d0ff *
menu color hotsel       1;7;37;40 #ffffffff #76a1d0ff *
menu color tabmsg       * #ffffffff #00000000 *
menu color help         37;40 #ffdddd00 #00000000 none

LABEL previous
  Menu LABEL ^Backup to Previous Menu
  kernel menu.c32
  #append boot-screens/os.txt
  Menu exit
menu separator

EOH
  ) > $DEB_BOOTSCREENS;

  for rel in $(ls $DEB_ROOT); do
    [ -d "${DEB_ROOT%%/}/$rel" ] || continue;
    rel_version=$(curl -s ${DEB_MIRROR%%/}/dists/$rel/Release|egrep 'Suite|Version'|tr -d \ |cut -d: -f2|tr [:space:] ' ')
    rel_version=$(echo $rel_version|sed -e "s/$rel//;s/^\s*//;s/\s*$//;")
    ( cat <<EOR
Menu Begin $rel
  MENU TITLE ${DISTRO_TITLE} $rel $rel_version Menu
  menu default
  LABEL Backup
    menu label ^Backup to Previous Menu
    Menu exit
  menu separator

EOR
  ) >> $DEB_BOOTSCREENS;

    local append_line="vga=788 locale=en_US.UTF-8 keymap=us time/zone=US/Central clock-setup/utc=true clock-setup/ntp-server=us.pool.ntp.org grub-installer/only_debian=true protocol=http mirror/http/directory=/${DISTRO} mirror/country=manual mirror/http/proxy= mirror/http/hostname=${MIRROR_BASE}"
    if [ "ubuntu" = "$DISTRO" ]; then
      append_line="$append_line mirror/http/mirror=${MIRROR_BASE}"
    fi

    for arch in $(ls $DEB_ROOT/$rel); do
      ( cat <<EOA
  Menu Begin $arch
    MENU TITLE ${DISTRO_TITLE} $rel $rel_version $arch
    LABEL Backup
      menu label ^Backup to Previous Menu
      Menu exit
    menu separator

    label expert
      menu label ^Expert install
      kernel ${DISTRO}-installer/$rel/$arch/linux
      append initrd=${DISTRO}-installer/$rel/$arch/initrd.gz priority=low $append_line --- 
    label install
      menu label ^Install
      menu default
      kernel ${DISTRO}-installer/$rel/$arch/linux
      append initrd=${DISTRO}-installer/$rel/$arch/initrd.gz $append_line --- quiet 
    label rescue
      menu label ^Rescue mode
      kernel ${DISTRO}-installer/$rel/$arch/linux
      append initrd=${DISTRO}-installer/$rel/$arch/initrd.gz vga=788 rescue/enable=true --- quiet
  menu end

EOA
  ) >> $DEB_BOOTSCREENS;

    done;
    ( cat <<EOR
Menu End

EOR
  ) >> $DEB_BOOTSCREENS;

  done;
    ( cat <<EOT

IPAPPEND 2
EOT
  ) >> $DEB_BOOTSCREENS;
}

