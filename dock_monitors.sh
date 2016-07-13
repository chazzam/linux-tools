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
# These should show up after running the 'setprovideroffloadsink'
# and 'setprovideroutputsource' xrandr commands below
EXTERNAL_ONE="DP-1-1"
EXTERNAL_TWO="DP-1-2"
EXTERNAL_TWO="VGA2"
EXTERNAL_TWO="$(xrandr |grep VGA|grep \ connected|cut -d\  -f1)";
GAMMA_EXTERNAL_TWO="--gamma 0.83:0.86:0.90"
GAMMA_EXTERNAL_ONE=""

# Name of the discrete graphic card in `xrandr --listproviders`
# nouveau - if using open source driver for Nvidia cards
DISCRETE="nouveau"

# make sure both gpus are still available
# Did you forget to load a module!?
NV="$(xrandr --listproviders |grep -c $DISCRETE)";
INTEL="$(xrandr --listproviders |grep -c Intel)";
[ "$NV" != "" ] || ( echo "$DISCRETE device not found"; false; ) || exit 1;
[ "$INTEL" != "" ] || ( echo "Intel device not found"; false; ) || exit 1;

# requires RandR 1.4 or later
# This is the "magic" that makes Nvidia Optimus (and the AMD counterpart) work
xrandr --setprovideroffloadsink $DISCRETE Intel;
xrandr --setprovideroutputsource $DISCRETE Intel
#xrandr --setprovideroutputsource Intel $DISCRETE

# If we aren't in the dock, then do nothing!
# so we need to see if we have these extra displays available and connected
EXT1="$(xrandr |grep $EXTERNAL_ONE|grep \ connected|cut -d\  -f1)"
EXT2="$(xrandr |grep $EXTERNAL_TWO|grep \ connected|cut -d\  -f1)"
[ "$EXT1" != "" ] || ( echo "$EXTERNAL_ONE not found"; false; ) || exit 1;
[ "$EXT2" != "" ] || ( echo "$EXTERNAL_TWO not found"; false; ) || exit 1;

# Kept having issues where the name of this would change
# Sometimes its LVDS1, sometimes LVDS2
# so now we just get the connected LVDS and base around that
LVDS="$(xrandr |grep $SCREEN_INTERNAL|grep \ connected|cut -d\  -f1)";

# configure monitor layout!
xrandr --output $EXT1 --auto --left-of $LVDS $GAMMA_EXTERNAL_ONE || exit 1;
xrandr --output $EXT2 --auto --right-of $LVDS $GAMMA_EXTERNAL_TWO || exit 1;
xrandr --output $LVDS --primary $GAMMA_LVDS || exit 1;

# Consider adding another script to use `wmctrl` to auto-open and position windows
