#!/bin/sh
MIRROR_TC="http://tinycorelinux.net";
ROOT_TC="/srv/tftp/tc";
RELEASES_TC="4 5 6 7";
PATH_RELEASE="release/distribution_files";
FILES_X86="vmlinuz core.gz";
FILES_X86_64="vmlinuz64 corepure64.gz";

download_files() {
  local path="$1"
  local files="$2"

  [ -d $path ] || mkdir -p $path;
  for f in $files; do 
    ( cd $path;
      wget -nv -N --random-wait $MIRROR_TC/$path/$f.md5.txt $MIRROR_TC/$path/$f;
    )
  done;
}

download_all() {
  local r=

  ( cd $ROOT_TC;
    for r in $RELEASES_TC; do
      echo "Downloading files for TC $r.x";
      local path="$r.x/x86/$PATH_RELEASE";

      # Download x86 files
      download_files "$path" "$FILES_X86";

      # Don't support 4.x x86_64, pathing is busted and it was weak.
      [ "$r" = "4" ] && continue;

      # Download x86_64 files
      path="$(echo $path|sed -e 's#/x86/#/x86_64/#;')";
      download_files "$path" "$FILES_X86_64";
    done;
  )
}

download_all;

echo "Done";
