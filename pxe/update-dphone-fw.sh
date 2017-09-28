#!/bin/sh

# http://dphone.dl.digium.com/firmware/switchvox/
#   <fw-version>/*.eff

# http://downloads.digium.com/pub/telephony/res_digium_phone/firmware/
#   firmware_<fw-major-version>_package.tar.gz

WEB_ROOT="/var/www";
WEB_PATH="dphone/firmware";
AVAHI_SERVICES="/etc/avahi/services";
HOSTNAME="pecan.digium.internal";
AVAHI_SERVICE_NAME_PREFIX="FWP";

URL_SWITCHVOX="http://dphone.dl.digium.com/firmware/switchvox/";
URL_ASTERISK="http://downloads.digium.com/pub/telephony/res_digium_phone/firmware/";

#set -x;

# folder fw_ver
write_avahi_service() {
  local fw_folder="${1%%/}";
  local fw_ver="$2"; # 2_0_2_0_78957
  local service_name="$AVAHI_SERVICE_NAME_PREFIX $fw_ver";
  local avahi_service="$AVAHI_SERVICES/dphone-fw-${fw_ver}.service";
  local fw_path="$WEB_PATH/$fw_folder";

  # Try to make sure there are actually eff files here before going on
  [ -d "$WEB_ROOT/$fw_path" ] || return 0;
  [ ! -z "$(find $WEB_ROOT/$fw_path/ -name '*.eff'|head -n1)" ] || return 0;

  touch $avahi_service;
  [ -f $avahi_service ] || return -1;

  ( cat << EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
    <name>$service_name</name>
    <service>
        <type>_digiumproxy._udp</type>
        <port>80</port>
        <txt-record>sipUrl=http://$HOSTNAME</txt-record>
        <txt-record>firmwareUrl=http://$HOSTNAME/</txt-record>
        <txt-record>firmwareVersion=$fw_ver</txt-record>
        <txt-record>serviceType=firmware</txt-record>
EOF
  ) > $avahi_service

  for eff in $(cd $WEB_ROOT/$fw_path/;find -maxdepth 1 -type f -name '*.eff'|sort); do
    # 2_0_2_0_78957_D40_firmware.eff
    #local model="${eff##${fw_ver}_}";
    #model="${model%%_firmware.eff}";
    eff=${eff##./}
    local model=$(echo $eff|sed -e 's/.*_\(D[0-9]\{2\}\)_.*\.eff/\1/;');
    ( cat << EOF
        <txt-record>${model}File=$fw_path/$eff</txt-record>
EOF
    ) >> $avahi_service
    sed -i -e "s#</name># $model</name>#" $avahi_service
  done;

  ( cat << EOF
    </service>
</service-group>

EOF
  ) >> $avahi_service
}

# ()
download_switchvox_firmware() {
  for fw in $(curl -k $URL_SWITCHVOX 2>/dev/null|\
    sed -e 's/</\n</g;'|\
    grep href|egrep '[0-9_]{7,}'|\
    cut -d\" -f2|tr -d \/|sort\
  ); do
    fw=${fw%%/};
    # flag the major firmware version without the build number
    local fw_flag_short="$WEB_ROOT/$WEB_PATH/.${fw%_[0-9a-f][0-9a-f]*}";
    local fw_flag="$WEB_ROOT/$WEB_PATH/.${fw}";
    [ -f $fw_flag ] && continue;
    printf "Adding firmware: %s\n" $fw
    local fw_path="$WEB_ROOT/$WEB_PATH/$fw";
    [ -d $fw_path ] || mkdir -p $fw_path;

    for eff in $(curl -k $URL_SWITCHVOX/$fw/  2>/dev/null|\
      sed -e 's/</\n</g;'|\
      grep href|egrep '[0-9_a-f]{7,}'|\
      cut -d\" -f2|tr -d \/|sort\
    ); do
      [ -f "$fw_path/$eff" ] && continue;
      ( cd $fw_path;
        wget -nv --no-check-certificate -N "${URL_SWITCHVOX%%/}/$fw/$eff";
      );
    done;
    touch "$fw_flag" "$fw_flag_short";sync;
    chown www-data:www-data -R $fw_path "${fw_flag_short}"*;
    chmod g+rwX -R $fw_path "${fw_flag_short}"*;
  done;
}

# ()
download_asterisk_firmware() {
  local fw_path="$WEB_ROOT/$WEB_PATH";
  for tarball in $(curl -k $URL_ASTERISK 2>/dev/null|\
    sed -e 's/</\n</g;'|\
    grep href|egrep '[0-9_]{7,}'|\
    cut -d\" -f2|tr -d \/|sort\
  ); do
    local fw="${tarball%_package.tar.gz}";
    fw="${fw##firmware_}";
    #fw="${fw//_package/}";
    # strip any build number off the fw version
    local fw_flag_short="$fw_path/.${fw%_[0-9a-f][0-9a-f]*}";
    local fw_flag="$fw_path/.${fw}";
    [ -f $fw_flag_short ] && continue;
    printf "Adding firmware: %s\n" $fw
    wget --no-check-certificate -nv -O "/tmp/$tarball" "${URL_ASTERISK%%/}/$tarball";
    # extract tarball
    tar -zxf "/tmp/$tarball" -C "$fw_path/";
    # TODO: need to get build rev
    local folder=$(basename -s .tar.gz $tarball)
    local full_version=$(cd $fw_path/$folder;find -name '*.eff'|head -n1)
    full_version=${full_version%%_D[0-9]*}
    full_version=${full_version##./}
    fw_flag="$fw_path/.${full_version}"
    mv $fw_path/$folder $fw_path/$full_version
    touch "$fw_flag" "$fw_flag_short";sync;
  done;
  chown www-data:www-data -R $fw_path;
  chmod g+rwX -R $fw_path;
}

write_avahi_service_files() {
  local fw_path="$WEB_ROOT/$WEB_PATH";
  for dir in $(cd $fw_path; find -maxdepth 1 -type d); do
    dir="${dir#.}";
    dir="${dir#/}";
    [ -z "$dir" ] && continue;
    [ "$dir" = "." ] && continue;
    [ -z "$(find $fw_path/$dir -name '*.eff')" ] && continue;
    # get the firmware version from an eff file
    local fw="$(cd $fw_path/$dir; find -maxdepth 1 -name '*.eff'|head -n1)";
    fw="${fw%%_D*}";
    fw="${fw#./}";
    write_avahi_service "$dir" "$fw";
  done;
}

echo "Beginning downloads";
download_switchvox_firmware;
download_asterisk_firmware;
echo "Writing Avahi service files";
write_avahi_service_files;
sync;
echo "Done";
