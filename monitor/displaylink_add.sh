#!/bin/bash

#sudo systemctl start displaylink
#sleep 4

SERVICE_DISPLAYLINK="$(systemctl status displaylink|grep Active|cut -d\  -f5)"
MOD_UDL="$(lsmod|grep -o ^udlf*)"
if [ "$SERVICE_DISPLAYLINK" = "inactive" ] && [ -z "$MOD_UDL" ]; then
  sleep 4;
  systemctl start displaylink;
  sleep 4;
fi;

# Handle name changing of LVDS, and we base arrangement on the DP-1-1 screen
LVDS="$(xrandr |grep LVDS|grep \ connected|cut -d\  -f1)"
DP1="$(xrandr |grep DP-1-1|grep \ connected|cut -d\  -f1)"

# make sure the device is connected, and then more "magic"
UDL="$(xrandr --listproviders |grep -c modesetting)";
[ "$UDL" = "1" ] || ( echo "more than one UDL device"; false; ) || exit 1;
xrandr --setprovideroutputsource modesetting Intel

DVI="$(xrandr |grep DVI|cut -d\  -f1)";
[ "$DVI" != "" ] || ( echo "No DVI device detected"; false; ) || exit 1;

# works on an e1649Fwu DisplayLink USB display, YMMV.
# Recommend looking up correct settings for your display
# or try `gtf` or `cvt` to generate the modeline
xrandr --newmode "1368x768_72.00"  104.73  1368 1448 1592 1816  768 769 772 801  -HSync +Vsync
xrandr --addmode $DVI 1368x768_72.00
xrandr --newmode "1368x768_59.90"  85.72  1368 1440 1584 1800  768 769 772 795  -HSync +Vsync
xrandr --addmode $DVI 1368x768_59.90

# Handle screen layout
# If not in the dock, then add the displaylink to the left of the screen
if [ "$DP1" != "" ]; then
  xrandr --output $DVI --below $DP1 --mode 1368x768_72.00
else
  xrandr --output $DVI --left-of $LVDS --mode 1368x768_72.00
fi
