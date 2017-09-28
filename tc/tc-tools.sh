alias errcho='>&2 echo';
WGET="$(which wget) -w2 --random-wait -nv --show-progress --no-check-certificate";
# do we need to add '--content-on-error' to wget options to continue on error?
SUDO=$(which sudo);
WEB_ROOT="/var/www";
WEB_PATH="corelinux";
#TC_ARCHES="armv6 armv7 mips x86 x86_64";
TC_ARCHES="x86 x86_64";
#TC_VERS="4 5 6 7"
TC_VERS="7"
TC_MIRROR="http://repo.tinycorelinux.net/"
TC_MIRROR_ALT="http://distro.ibiblio.ord/tinycorelinux/"
TC_KERNEL_4="3.0.21-tinycore"
TC_KERNEL_5="3.8.13-tinycore"
TC_KERNEL_6="3.16.6-tinycore"
TC_KERNEL_7="4.2.9-tinycore"

update_available_package_list() {
  # All packages must be listed in info.lst for the tiny core package manager to find them on the mirror.
  # .info files are apparently required for TC, as this is the routine provided by tiny core linux for maintaining
  #  a custom mirror for TC packages.
  # This routine first deletes the current info.lst, then rebuilds it from the list of info files.
  # info.lst is just a list of the packages that have info files
  # tags.db is that plus the Description from the info field

  [[ -n "$1" ]] && [[ -d "$1" ]] || exit 1;
  echo "Updating mirror's package list: $(pwd)";
  ( cd "$1";
    rm info.lst tags.db;
    for i in `ls -1 -- *.info|sort -f`; do
      local tmp="$(basename -- "$i" .info)";
      local desc="$(grep Description $i | sed -e s/Description:\\s\\+//)";
      echo "$tmp" >> info.lst;
      echo -e "$tmp\t\t\t\t\t$desc" >> tags.db;
    done;

    gzip -c9 info.lst > info.lst.gz;
    gzip -c9 tags.db > tags.db.gz;
  );
  echo "Finished updating package list";
}

download_dir_tcz_lists() {
  local tcz_path="${1%%/}";
  local mirror="${2%%/}";
  local dl_path="$WEB_ROOT/$WEB_PATH/$tcz_path";
  [ -d "$dl_path" ] || mkdir -p "$dl_path";

  echo "Updating extension lists for '$dl_path' ...";
  ( cd $dl_path;
    rm -rf {info.lst,info.lst.gz,tags.db.gz,provides.db,provides.db.gz};
    $WGET -nd -N -- $mirror/$tcz_path/{info.lst,info.lst.gz,tags.db.gz,provides.db,provides.db.gz};
  )
}

download_tcz_lists() {
  local tc_vers="$1";
  local url="${2%%/}";

  for ver in $tc_vers; do
    for arch in $TC_ARCHES; do
      local path="$ver.x/$arch/tcz";
      download_dir_tcz_lists "${path%%/}" "$url"
    done;
  done;
}

tc_kernel_ver() {
  local tc_ver="$1";
  local arch="${2:-x86}";
  local kernel_ver="$TC_KERNEL_7";

  case $tc_ver in
    7)
      kernel_ver=$TC_KERNEL_7;
      ;;
    6)
      kernel_ver=$TC_KERNEL_6;
      ;;
    5)
      kernel_ver=$TC_KERNEL_5;
      ;;
    4)
      kernel_ver=$TC_KERNEL_4;
      ;;
    *)
      kernel_ver=$TC_KERNEL_7;
      ;;
  esac
  if [ "${arch%%64}" != "$arch" ]; then
    kernel_ver="${kernel_ver}64";
  fi;
}

update_release_dirs() {
  # x86/release/distribution_files
  # core.gz{,.md5.txt}, vmlinuz{,.md5.txt}
  # x86_64/release/distribution_files
  # corepure64.gz{,.md5.txt}, vmlinuz64{,.md5.txt}
  # x86/release/src/kernel/
  # config-KERNEL, linux-KERNEL_VER-patched.txz, Module.symvers-KERNEL.gz
  # x86_64/release/src/kernel/
  # config-KERNEL, Module.symvers-KERNEL.gz

  local include_dirs=""
  local include_files="'core*.gz','vmlinuz*','Module.symvers*.gz'"
  local exclude_dirs=""
  local dl_path="$WEB_ROOT/$WEB_PATH/";

  for ver in $TC_VERS; do
    local path_ver="/${ver}.x"
    local tc_kernel=$(tc_kernel_ver $ver x86)
    exclude_dirs="${exclude_dirs},${path_ver}/*/archive,${path_ver}/*/tcz,${path_ver}/*/release_candidates"
    include_files="${include_files},'config-${tc_kernel}*','linux-${tc_kernel%%-tinycore*}-patched.txz'"
    for arch in $TC_ARCHES; do
      path_ver="${path_ver}/${arch}"
      include_dirs="${include_dirs},${path_ver}"
    done;
  done;
  include_dirs="${include_dirs##,}"
  exclude_dirs="${exclude_dirs##,}"
  include_files="${include_files##,}"
  [ -z "$include_dirs" ] || include_dirs="-I $include_dirs"
  [ -z "$exclude_dirs" ] || exclude_dirs="-X $exclude_dirs"
  [ -z "$include_files" ] || include_files="-A $include_files"
  wget -nv -np -r -nH -N --random-wait -w4 -P $dl_path $include_dirs \
       $exclude_dirs $include_files $TC_MIRROR 
}


update_dir_md5s() {
  local dir="${1%%/}";
  local url="${2%%/}";
  local path="$WEB_ROOT/$WEB_PATH/$dir";
  [ -d $path ] || return 0;

  ( cd $path;
    sed -e "s#\(.*\.tcz\)#$url/$dir/\1.md5.txt#;" info.lst |
    $WGET -nd -N -i- --;
  )
}

update_md5s() {
  local tc_vers="$1";
  local url="${2%%/}"

  for ver in $tc_vers; do
    for arch in $TC_ARCHES; do
      local path="$ver.x/$arch/tcz";
      echo "Updating md5's for TC $ver $arch...";
      update_dir_md5s ${path%%/} "$url";
    done;
  done;
}

find_failures() {
  local path="${1%%/}";
  [ -d $path ] || return 0;

  local failed="$(
    ( cd $path;
        md5sum -c *.md5.txt 2>&1 | 
        grep -Ev 'OK|WARNING' | 
        sed -e 's/^md5sum: //;';
    ) | cut -d: -f1 | sed -e 's/\.tcz.*/.tcz\*/';
  )";
  echo -- $failed;
}

remove_dir_faileds() {
  local dir="${1%%/}";
  local path="$WEB_ROOT/$WEB_PATH/$dir";
  [ -d $path ] || return 0;

  local failed="$(find_failures $path)"
  if [ -z "$failed" ]; then
    printf "No failures found for: %s\n" "$path";
  else
    printf "removing md5sum failues: %s\n" "$failed";
    ( cd $path;
      rm -f $failed;
    );
  fi;
}

remove_failed_extensions() {
  # find any failed md5sums and remove those extensions
  local tc_vers="$1";

  printf "Scanning for failed extensions...\n"
  for ver in $tc_vers; do
    for arch in $TC_ARCHES; do
      local path="$ver.x/$arch/tcz";
      remove_dir_faileds $path &
    done;
  done;
  wait;
}

update_dir_faileds() {
  local dir="${1%%/}";
  local url="${2%%/}";
  local path="$WEB_ROOT/$WEB_PATH/$dir";
  [ -d $path ] || return 0;

  ( cd $path;
    ( 
        md5sum -c *.md5.txt 2>&1 | \
        grep -Ev 'OK|WARNING' | \
        sed -e 's/^md5sum: //;';
    ) |cut -d: -f1|sort|uniq|\
      sed -e "s#\(.*\)\.tcz.*#$url/$dir/\1.tcz#"|\
      awk '/.tcz/ { printf("%s\n%s.md5.txt\n%s.dep\n%s.info\n%s.list\n%s.tree\n%s.zsync\n",$1,$1,$1,$1,$1,$1,$1); }'|\
      $WGET -nd -N -i- --;
  );
}

update_failed_extensions() {
  # find any failed md5sums and remove those extensions
  local tc_vers="$1";
  local url="${2%%/}"

  for ver in $tc_vers; do
    for arch in $TC_ARCHES; do
      local path="$ver.x/$arch/tcz";
      echo "Updating failed extensions for TC $ver $arch";
      update_dir_faileds $path $url;
    done;
  done;
}

# As this is currently written, you probably have to run it several times
# in order to actually pull in all the dependencies.
update_testing_mirror_symlinks() {
# $1 - path to TCZ directory within mirror locations
# $2 - kernel version for corresponding TCZ directory
  local dir_testing="/var/www/tinycore-testing";
  local dir_production="/var/www/corelinux";
  local dir_tcz="";
  if [[ -n "$1" && -d "$1" ]]; then
    dir_tcz="$1";
  else
    dir_tcz="4.x/x86/tcz/";
  fi
  local tc_kernel="";
  if [[ -n "$2" ]]; then
    tc_kernel="$2";
  else
    tc_kernel="3.0.21-tinycore";
  fi

  # Currently, only examining the deps of packages in testing
  for pkg in $(cat "$dir_testing"/"$dir_tcz"/*.dep); do
    # Replace instances of KERNEL with a kernel version
    pkg=${pkg/KERNEL/$tc_kernel};
    for ext in '' .dep .md5.txt .info .zsync; do
      local pkg_t="$dir_testing"/"$dir_tcz"/"${pkg}${ext}";
      local pkg_p="$dir_production"/"$dir_tcz"/"${pkg}${ext}";
      # Skip if non-existant in production
      [[ -e "$pkg_p" ]] || continue;
      # Skip if this already exists in testing (as symlink or file),
      # Otherwise create the symlink
      if ! [[ -L "$pkg_t" || -f "$pkg_t" ]]; then 
        ln -s "$pkg_p" "$dir_testing"/"$dir_tcz"/ && \
          echo "linked ${pkg}${ext}" || \
          errcho "linking ${pkg}${ext} FAILED: '$pkg_p' -> '$pkg_t'";
      fi;
    done;
  done;
  # Update the list of packages available in the testing directory.
  update_available_package_list "$dir_testing"/"$dir_tcz"/
}

update_tc_mirror_paths() {
  local tcz="$1";
  local mirror="$2";

  [ ! -z "$mirror" ] && TC_MIRROR="$mirror";
  [ ! -z "$tcz" ] && TC_TCZ="$tcz";
}


download_package() {
  # This downloads all the bits from the mirror related to the package.
  # expects the base package name (no .tcz) as the only argument
  local pkg="${1%%.tcz*}.tcz";
  pkg="${TC_TCZ}/${pkg}";

  # Ensure that the .tcz and .md5.txt download without error
  $WGET -O "${pkg}" -- "${TC_MIRROR}/${pkg}";
  if [ $? != 0 ]; then
    echo "Failed to download tcz package";
    exit 4;
  fi;
  $WGET -O "${pkg}.md5.txt" -- "${TC_MIRROR}/${pkg}.md5.txt";
  if [ $? != 0 ]; then
    echo "Failed to download tcz package md5sums, cannot verify package";
    exit 6;
  fi;
  # The other bits aren't quite as important... not all packages even have .dep files.
  $WGET -O "${pkg}.dep" -- "${TC_MIRROR}/${pkg}.dep" 2>/dev/null;
  $WGET -O "${pkg}.info" -- "${TC_MIRROR}/${pkg}.info" 2>/dev/null;
  $WGET -O "${pkg}.list" -- "${TC_MIRROR}/${pkg}.list" 2>/dev/null;
  $WGET -O "${pkg}.tree" -- "${TC_MIRROR}/${pkg}.tree" 2>/dev/null;
  $WGET -O "${pkg}.zsync" -- "${TC_MIRROR}/${pkg}.zsync" 2>/dev/null;
}

verify_package() {
  # Check the md5sum of the package. if its a match move on
  # If not, then try downloading it one more time.
  local pkg="${1%%.tcz*}.tcz";
  $(cd $TC_TCZ;md5sum -c "${pkg}.md5.txt");
  if [ $? != 0 ]; then
    # Give one more change to download correctly. if it still fails, die.
    download_package "${pkg}";
    $(cd $TC_TCZ;md5sum -c "${pkg}.md5.txt");
    if [ $? != 0 ]; then
      echo "Failed to verify package ${pkg} Will now exit";
      exit 9;
    fi;
  fi;
}

download_and_verify_packages() {
  # Takes a list of "package names", then tries to download all the bits related to it
  # Then verify the .tcz using the .tcz.md5.txt. should exit on a failure to verify.
  #echo "Beginning package download(s)";
  local pkg=;
  for pkg in $@;
  do
    echo "begin downloading $pkg";
    download_package $pkg;
    verify_package $pkg;
  done;
}

get_dep_level() {
  local prev_all="$DEPS_ALL";
  LEV_COUNT=$(expr $LEV_COUNT + 1);
  LEV_NOW=$(cat $(echo $LEV_PREV) 2>/dev/null|\
    sed "s/\.tcz.*/.tcz.dep\n/g;s/^\s*$//;"|sort|uniq\
  );
  DEPS_ALL=$(echo $DEPS_ALL $LEV_NOW|tr " " "\n"|sort|uniq);
  LEV_PREV="$LEV_NOW";
  LEV_REM=$(echo $prev_all $DEPS_ALL|tr " " "\n"|sort|uniq -u);
}

get_deps() {
  local dir="${1%%/}";
  shift;
  DEPS_ALL=$(
    cd "$dir";
    LEV_REM="";
    LEV_NOW="";
    DEPS_ALL="";
    LEV_COUNT=0;
    LEV_PREV=$(cat $@ 2>/dev/null|
      sed "s/\.tcz.*/.tcz.dep\n/g;s/^\s*$//;"|sort|uniq
    );
    until [ -z "$LEV_REM" -o "$LEV_COUNT" -ge 40 ] && [ "$LEV_COUNT" -ge 1 ]; do
      get_dep_level;
    done;
    echo $DEPS_ALL;
  );
  echo $DEPS_ALL;
}

download_deps() {
  local url="${1%%/}";
  shift;
  local path="${1%%/}";
  shift;
  local dir="$WEB_ROOT/$WEB_PATH/$path";
  ( cd $dir;
    get_deps "$dir" $@|
    tr " " "\n"|
    sed -e "s#\(.*\)\.tcz.*#$url/$path/\1.tcz#"|
    awk '/.tcz/ { printf("%s\n%s.md5.txt\n%s.dep\n%s.info\n%s.list\n%s.tree\n%s.zsync\n",$1,$1,$1,$1,$1,$1,$1); }'|
    $WGET -nd -N -i- --;
  );
}
