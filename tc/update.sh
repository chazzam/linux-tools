#!/bin/bash
#set -x;
# This is a list of the basenames for packages we create for the tester, separated by '|' (pipe)
IGNORE_PACKAGES="libnewt|perl-tester-modules|libpri|dahdi|asterisk|prodtest";

# The location on disk where the packages are to be hosted from, should be available via 'HTTP' as */tinycorelinux
# Tinycore has issues with HTTPS unless the actual wget package is installed, so avoid HTTPS
MIRROR_DIR="/var/www/tinycorelinux";

# Information about the mirror and the locations for the tcz packages and the iso releases.
TC_MIRROR="http://distro.ibiblio.org/tinycorelinux";
TC_TCZ="4.x/x86/tcz";
TC_RELEASE="4.x/x86/release";

# We need to know the kernel version for dependency resolution.
TC_KERNEL_VERSION="3.0.21-tinycore";

# Set up our wget command to be quieter, and to work on https links.
WGET="$(which wget) -nv --no-check-certificate";

#  Will create directory structure from MIRROR_DIR directory specified above.
#  This path should be accessible via http with a prefix of "tinycorelinux"
#  HTTPS not supported
#
# Usage:
#    No arguments    - update package info list (always performed)
#    Package name(s) - download packages specified
#    -U | --update   - download updates for existing packages and the ISO

download_package() {
  # This downloads all the bits from the mirror related to the package.
  # expects the base package name (no .tcz) as the only argument
  pkg="$(echo $1 | sed -e 's/\.tcz.*//;')";

  # Ensure that the .tcz and .md5.txt download without error
  $WGET -O "${pkg}.tcz" -- "${TC_MIRROR}/${TC_TCZ}/${pkg}.tcz";
  if [ $? != 0 ]; then
    echo "Failed to download tcz package";
    exit 4;
  fi;
  $WGET -O "${pkg}.tcz.md5.txt" -- "${TC_MIRROR}/${TC_TCZ}/${pkg}.tcz.md5.txt";
  if [ $? != 0 ]; then
    echo "Failed to download tcz package md5sums, cannot verify package";
    exit 6;
  fi;
  # The other bits aren't quite as important... not all packages even have .dep files.
  $WGET -O "${pkg}.tcz.dep" -- "${TC_MIRROR}/${TC_TCZ}/${pkg}.tcz.dep" 2>/dev/null;
  $WGET -O "${pkg}.tcz.info" -- "${TC_MIRROR}/${TC_TCZ}/${pkg}.tcz.info";
  $WGET -O "${pkg}.tcz.list" -- "${TC_MIRROR}/${TC_TCZ}/${pkg}.tcz.list";
  $WGET -O "${pkg}.tcz.tree" -- "${TC_MIRROR}/${TC_TCZ}/${pkg}.tcz.tree";
  $WGET -O "${pkg}.tcz.zsync" -- "${TC_MIRROR}/${TC_TCZ}/${pkg}.tcz.zsync";
}

verify_package() {
  # Check the md5sum of the package. if its a match move on
  # If not, then try downloading it one more time.
  pkg="$(echo $1 | sed -e 's/\.tcz.*//;')";
  md5sum -c "${pkg}.tcz.md5.txt";
  if [ $? != 0 ]; then
    # Give one more change to download correctly. if it still fails, die.
    download_package "${pkg}";
    md5sum -c "${pkg}.tcz.md5.txt";
    if [ $? != 0 ]; then
      echo "Failed to verify package ${pkg}.tcz Will now exit";
      exit 9;
    fi;
  fi;
}

download_and_verify_packages() {
  # Takes a list of "package names", then tries to download all the bits related to it
  # Then verify the .tcz using the .tcz.md5.txt. should exit on a failure to verify.
  echo "Beginning package download(s)";
  for pkg in $@;
  do
    download_package $pkg;
    verify_package $pkg;
  done;
}

check_for_updates() {
  # This routine downloads the md5.txt of all the passed in "package names" and then verifies their md5sums.
  # For any that fail verification it will prompt whether to continue with removing and re-downloading
  # those packages. Do not accept for any packages that are created by us for the tester.
  # Those packages base names should go into the IGNORE_PACKAGES variable separated by '|' (pipe).

  # Use egrep to find the actual names of the packages from our ignore basename list
  ignores="$({ echo $@; } |tr ' ' '\n'|egrep -i "$IGNORE_PACKAGES")"
  # Then throw the packages under fire along with the ignore package names into uniq -u.
  # uniq -u removes anything that has a duplicate completely, leaving behind only the unique entries
  # This is why we have to put the $ignores in here twice, to guarantee they have at least one duplicate.
  packages="$({ echo $@;echo $ignores;echo $ignores; }|tr ' ' '\n'|sort|uniq -u)";

  echo "Checking for updates to existing packages";
  for file in $packages; do
    # Strip off any existing .tcz*, and always add .tcz.md5.txt to the end.
    file="$(echo $file | sed -e 's/\.tcz.*//;').tcz.md5.txt";
    # Make sure we don't do anything on empty space and such.
    if [ "" != "$file" ]; then
      # Download the .md5.txt and verify it
      $WGET  -O $file -- ${TC_MIRROR}/${TC_TCZ}/${file};
      md5sum -c $file 2>/dev/null;
      # on a failure we prompt for permission to continue and if granted delete the package and related bits.
      # then we try to redownload it.
      if [ "$?" != "0" ]; then
        # We had the name of the md5.txt, now get just the *.tcz
        pkg="$(basename -- $file .md5.txt)";
        echo "WARNING!! continuing will delete packages from the system and attempt";
        echo "to redownload them. Are you sure you want to continue and delete:";
        echo "${pkg}* ?: [yN]";
        read ans;
        if [ "1" == "$(echo $ans | grep -ci '^y$')" ]; then
          # delete only this .tcz*, don't delete it without tcz in case there are other packages with a similar name.
          rm ${pkg}*;
          # Get down to the base package name with no .tcz for downloading.
          pkg="$(basename -- $pkg .tcz)";
          download_and_verify_packages ${pkg};
        else
          # If permission is not granted, then we report that we skipped updating that one.
          echo -e "\n\nSkipping updating $pkg package\n\n";
        fi;
      fi;
    fi;
  done;
}

search_dependencies() {
  # This finds dependencies of packages already downloaded. Dependencies are stored in .tcz.dep
  # We use uniq -u again to remove all duplicated entries and get only the entries that are actually unique.
  # We have to list all the existing packages twice to guarantee that they all will have at least one duplicate
  # Then we list all the contents of all the .dep files
  # We then replace "KERNEL" with the kernel version of tiny core that we are dealing with. The TC package manager
  #  auto resolves "KERNEL" in "<package name>-KERNEL" to the actual installed kernel version, so there aren't any
  #  packages to download that have a -KERNEL in their name, so we need to account for that.
  MISSING="$({ ls *.tcz; ls *.tcz; cat *.dep | sed s/KERNEL/$TC_KERNEL_VERSION/ | tr -d ' '; } | sort | uniq -u | sed -e s/.tcz// )";
}

resolve_dependencies() {
  # This checks for any missing dependencies, downloads them, and repeats until no more
  # dependencies are returned.
  echo "Verifying all dependencies are present";
  search_dependencies;
  while [ "" != "$MISSING" ]; do
    download_and_verify_packages $MISSING;
    search_dependencies;
  done;
}

update_available_package_list() {
  # All packages must be listed in info.lst for the tiny core package manager to find them on the mirror.
  # .info files are apparently required for TC, as this is the routine provided by tiny core linux for maintaining
  #  a custom mirror for TC packages.
  # This routine first deletes the current info.lst, then rebuilds it from the list of info files.
  echo "Updating mirror's package list";
  rm info.lst
  for i in `ls -1 -- *.info|sort -f`; do
     basename -- "$i" .info >> info.lst
  done

  gzip -c9 info.lst > info.lst.gz
}

# Default to update list, then determine operating mode.
op="list";
if [ "-U" == "$1" ] || [ "--update" == "$1" ]; then
  op="update";
elif [ " $@" != " " ]; then
  op="download";
fi;

# Strip out any control args in the passed in parameter list.
args="$(echo " $@" | sed -e 's/ -U//g;s/ --update//g;')";
cur_dir="$(pwd)";

# save off our lab directory
cur_dir="$(pwd)";

# Create directories if they don't exist.
[ -d "$MIRROR_DIR" ] || mkdir -p "$MIRROR_DIR";
cd $MIRROR_DIR;
[ -d "${TC_TCZ}" ] || mkdir -p "${TC_TCZ}";
cd ${TC_TCZ};

# helpful intro message! But WAIT! THERE's MORE!!
echo "tinycore corelinux tcz/iso updater, fetcher, and initializer"; 

if [ "download" == "$op" ]; then
  # Download packages
  download_and_verify_packages $args;
elif [ "update" == "$op" ]; then
  # Update packages
  check_for_updates $(ls -- *.tcz.md5.txt) $args;
fi;

# Always resolve dependencies and update package info list.
resolve_dependencies;
update_available_package_list;

if [ "update" == $op ]; then
  echo "Downloading updated iso";
  # If we're going to update, then update the ISO we're building with as well.
  cd ${MIRROR_DIR};
  [ -d "${TC_RELEASE}" ] || mkdir -p "${TC_RELEASE}";
  cd ${TC_RELEASE};
  # Eventually, this needs to determine the latest version in the release directory
  # and download that instead of the -current. That would require updating the build script too though.
  # Would be better to have versions there from a maintainability standpoint. Would probably require `curl` though.
  $WGET -O Core-current.iso -- ${TC_MIRROR}/${TC_RELEASE}/Core-current.iso;
fi;

# Move back to the lab
cd $cur_dir;
echo "done!";
