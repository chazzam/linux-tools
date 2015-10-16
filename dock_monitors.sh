#!/bin/bash

# get the nvidia and intel chips
NV="$(xrandr --listproviders |grep -c nouveau)";
INTEL="$(xrandr --listproviders |grep -c Intel)";
[ "$NV" != "" ] || ( echo "Nouveau device not found"; exit 1; );
[ "$INTEL" != "" ] || ( echo "Intel device not found"; exit 1; );

# requires RandR 1.4 or later
xrandr --setprovideroffloadsink nouveau Intel;
xrandr --setprovideroutputsource nouveau Intel

# If we aren't in the dock, then do nothing!
# so we need to see if we have these extra displays available and connected
DP1="$(xrandr |grep DP-1-1|grep \ connected|cut -d\  -f1)"
DP2="$(xrandr |grep DP-1-2|grep \ connected|cut -d\  -f1)"
[ "$DP1" != "" ] || ( echo "DP-1-1 not found"; exit 1; );
[ "$DP2" != "" ] || ( echo "DP-1-2 not found"; exit 1; );

LVDS="$(xrandr |grep LVDS|grep \ connected|cut -d\  -f1)";

xrandr --output $DP1 --auto --left-of $LVDS
xrandr --output $DP2 --auto --right-of $LVDS
xrandr --output $LVDS --primary
