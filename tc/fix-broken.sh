. /var/www/corelinux/tc-tools.sh

#set -x;
main() {
  local test_dir="$WEB_ROOT/tinycore-testing";
  local mirror_dir="$WEB_ROOT/$WEB_PATH";
  for d in $(find $test_dir/ -maxdepth 2 -type d -name x86*); do
    d=${d#$test_dir};
    d=${d##/};
    [ -d $mirror_dir/$d/tcz ] || continue;
    [ -d $test_dir/$d/tcz ] || continue;
    download_deps "$TC_MIRROR" "$d/tcz/" "$test_dir/$d/tcz/*.tcz.dep";
  done;
}
main;
