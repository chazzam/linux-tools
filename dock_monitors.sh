#!/bin/bash

# Name of Onboard laptop display, 
# From a fresh X start, will likely be the only connected display 
# in output of `xrandr`
SCREEN_INTERNAL="LVDS"
# We don't use the full name of the display here due to issues
# with the name changing between boots/X restarts.
# It will check for the connected display using this as a name and pull that full name

# Names of the external displays to use
# One is configured to the left of Internal
# Two is configured to the right of Internal
EXTERNAL_ONE="DP-1-1"
EXTERNAL_TWO="DP-1-2"

# Name of the discrete graphic card in `xrandr --listproviders`
# nouveau - if using open source driver for Nvidia cards
DISCRETE="nouveau"

# make sure both gpus are still available
# Did you forge to load a module!?
NV="$(xrandr --listproviders |grep -c $DISCRETE)";
INTEL="$(xrandr --listproviders |grep -c Intel)";
[ "$NV" != "" ] || ( echo "$DISCRETE device not found"; exit 1; );
[ "$INTEL" != "" ] || ( echo "Intel device not found"; exit 1; );

# requires RandR 1.4 or later
# This is the "magic" that makes Nvidia Optimus work
xrandr --setprovideroffloadsink $DISCRETE Intel;
xrandr --setprovideroutputsource $DISCRETE Intel

# If we aren't in the dock, then do nothing!
# so we need to see if we have these extra displays available and connected
EXT1="$(xrandr |grep $EXTERNAL_ONE|grep \ connected|cut -d\  -f1)"
EXT2="$(xrandr |grep $EXTERNAL_TWO|grep \ connected|cut -d\  -f1)"
[ "$EXT1" != "" ] || ( echo "$EXTERNAL_ONE not found"; exit 1; );
[ "$EXT2" != "" ] || ( echo "$EXTERNAL_TWO not found"; exit 1; );

# Kept having issues where the name of this would change
# Sometimes its LVDS1, sometimes LVDS2
# so now we just get the connected LVDS and base around that
LVDS="$(xrandr |grep $SCREEN_INTERNAL|grep \ connected|cut -d\  -f1)";

# configure monitor layout!
xrandr --output $EXT1 --auto --left-of $LVDS
xrandr --output $EXT2 --auto --right-of $LVDS
xrandr --output $LVDS --primary

# Consider adding another script to use `wmctrl` to auto-open and position windows