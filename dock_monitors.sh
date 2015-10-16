#!/bin/bash

# make sure both gpus are still available
# Did you forge to load a module!?
NV="$(xrandr --listproviders |grep -c nouveau)";
INTEL="$(xrandr --listproviders |grep -c Intel)";
[ "$NV" != "" ] || ( echo "Nouveau device not found"; exit 1; );
[ "$INTEL" != "" ] || ( echo "Intel device not found"; exit 1; );

# requires RandR 1.4 or later
# This is the "magic" that makes Nvidia Optimus work
xrandr --setprovideroffloadsink nouveau Intel;
xrandr --setprovideroutputsource nouveau Intel

# If we aren't in the dock, then do nothing!
# so we need to see if we have these extra displays available and connected
DP1="$(xrandr |grep DP-1-1|grep \ connected|cut -d\  -f1)"
DP2="$(xrandr |grep DP-1-2|grep \ connected|cut -d\  -f1)"
[ "$DP1" != "" ] || ( echo "DP-1-1 not found"; exit 1; );
[ "$DP2" != "" ] || ( echo "DP-1-2 not found"; exit 1; );

# Kept having issues where the name of this would change
# Sometimes its LVDS1, sometimes LVDS2
# so now we just get the connected LVDS and base around that
LVDS="$(xrandr |grep LVDS|grep \ connected|cut -d\  -f1)";

# configure monitor layout!
xrandr --output $DP1 --auto --left-of $LVDS
xrandr --output $DP2 --auto --right-of $LVDS
xrandr --output $LVDS --primary
