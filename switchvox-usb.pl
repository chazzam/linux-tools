#!/usr/bin/perl -w
use strict;
use File::Temp qw(tempdir mkdtemp);
use File::Basename;
use File::Spec;
use Getopt::Long qw(:config bundling);
use Pod::Usage;

# Required utilities:
#  parted, fdisk, sfdisk, syslinux, losetup, cpio,
#  find, mount, cp|rsync, mkdir, dd, wget|curl
# packages: perl-doc, parted, rsync, syslinux, wget

# This will probably require running with elevated privileges (e.g. root)

#
# See documentation, usage, and HELP at end of file.
#

my $Default_Timeout = 600;
my %opts = (
  'h' => 0,
  'help' => 0,
);

GetOptions(\%opts, 'help', 'h',
  'output|o=s@', 'loop-dev|l=s', 'profile|p=s', 'syslinux=s',
  'tools!', 'root!', 'poweroff!', 'reboot!',
  'timeout=i', 'timezone=s',
);

pod2usage(-exitval => 0, -verbose => 1) if ($opts{'h'});
pod2usage(-exitval => 0, -verbose => 2) if ($opts{'help'});

my %profiles = (
  'default' => {
    'timezone' => "",
    'timeout' => $Default_Timeout,
    'root' => 0,
    'tools' => 1,
    'poweroff' => 0,
    'reboot' => 0,
  },
  'est' => {
    'timezone' => "--utc America/New_York",
    'timeout' => $Default_Timeout,
    'root' => 0,
    'tools' => 0,
    'poweroff' => 1,
    'reboot' => 0,
    'ontimeout' => 'switchvox',
  },
  'cst' => {
    'timezone' => "--utc America/Chicago",
    'timeout' => $Default_Timeout,
    'root' => 0,
    'tools' => 0,
    'poweroff' => 1,
    'reboot' => 0,
    'ontimeout' => 'switchvox',
  },
  'pst' => {
    'timezone' => "--utc America/Los_Angeles",
    'timeout' => $Default_Timeout,
    'root' => 0,
    'tools' => 0,
    'poweroff' => 1,
    'reboot' => 0,
    'ontimeout' => 'switchvox',
  },
  'eng' => {
    'timezone' => "--utc America/Chicago",
    'timeout' => $Default_Timeout,
    'root' => 1,
    'tools' => 0,
    'poweroff' => 1,
    'reboot' => 0,
    'all-kickstarts' => 1,
  },
  'ops' => {
    'timezone' => "--utc America/Chicago",
    'timeout' => $Default_Timeout,
    'root' => 0,
    'tools' => 1,
    'poweroff' => 1,
    'reboot' => 0,
    'all-kickstarts' => 1,
    'output' => ['tgz'],
  },
);

pod2usage(-exitval => 1, -verbose => 1) if (@ARGV > 2 or @ARGV < 1);
my $Switchvox_iso = shift;
$Switchvox_iso = File::Spec->rel2abs($Switchvox_iso);
die "Must specify an existing and readable Switchvox ISO\n"
  unless ($Switchvox_iso and -r $Switchvox_iso);

# Verify that any specified profile is valid
if (exists($opts{'profile'})) {
  # aliases
  $opts{'profile'} = "default" if ($opts{'profile'} eq 'standard');

  my $found = 0;
  foreach my $p (keys(%profiles)) {
    if ( uc($opts{'profile'}) eq uc($p) ) {
      $found = 1;
      # Configure %opts with the profile:
      #  timeout, timezone, root, poweroff, reboot, tools
      foreach my $opt ( keys(%{$profiles{$p}}) ) {
        # Only apply the option if it hasn't already been applied.
        # This allows for individual options from a profile to be overridden
        $opts{$opt} = $profiles{$p}->{$opt} unless ( exists($opts{$opt}) );
      }
      last;
    }
  }
  die "Must specify a valid configuration profile\n" unless ($found);
}
$opts{'ontimeout'} = 'bootlocal' unless ( exists($opts{'ontimeout'}) );

my $Output_Image = 0;
# Only allow certain specified output formats
my %outputs = (
  'img' => 'img',
  'tgz' => 'tar --exclude=#x# -vczf #archive# #files#',
  'zip' => 'zip -r #archive# #files# -x #x#',
);
# Add aliases
$outputs{'tarball'} = $outputs{'tgz'};
# Validate any passed in output types
unless ( exists($opts{'output'}) ) {
  # Handle the case where nothing is passed in for output
  $opts{'output'} = ['img'];
  $Output_Image = 1;
} else {
  foreach my $out ( @{$opts{'output'}} ) {
    my $found = 0;
    # If this output is in the allowed list, allow it.
    foreach my $allowed (keys(%outputs)) {
      if (uc($out) eq uc($allowed)) {
        $found = 1;
        last;
      }
    }
    die "Must specify only valid output formats: $out\n" unless ($found);
    $Output_Image = 1 if (uc($out) eq "IMG");
  }
}

die "Must have cpio installed\n" unless (`which cpio` ne "");
sub find_syslinux_files($) {
  my $dir = shift;

  unless (defined $dir and -e $dir and -r $dir and -d $dir) {
    return 0;
  }
  else {
    # Try to find the needed syslinux files
    my $command = 'find '.$dir.' -name "mbr.bin"|head -n1';
    chomp(my $mbr = `$command`);
    $opts{'mbr_bin'} = $mbr if (-r $mbr);

    $command = 'find '.$dir.' -name "menu.c32"|head -n1';
    chomp(my $menu = `$command`);
    $opts{'menu_c32'} = $menu if (-r $menu);
  }
  if (
    exists($opts{'menu_c32'}) and -r $opts{'menu_c32'} and
    exists($opts{'mbr_bin'}) and -r $opts{'mbr_bin'}
  ) {
    return 1;
  }
  else {
    delete $opts{'menu_c32'};
    delete $opts{'mbr_bin'};
  }
  return 0;
}

if ($Output_Image) {
  die "Must have losetup installed\n" unless (`which losetup` ne "");

  $opts{'loop-dev'} = '/dev/loop0' unless ( exists($opts{'loop-dev'}) );
  die "Must have a valid loop device, e.g. /dev/loop0\n"
    unless (-e $opts{'loop-dev'});
  die "Loop device is in use, try a different device with --loop-dev\n"
    if (`losetup -a` =~ /$opts{'loop-dev'}/);

  die "Must have parted installed\n" unless (`which parted` ne "");
  die "Must have fdisk installed\n" unless (`which fdisk` ne "");
  die "Must have syslinux installed\n" unless (`which syslinux` ne "");

  unless (exists($opts{'syslinux'})) {
    # try to find the default syslinux install
    # Debian/Ubuntu /usr/lib/syslinux/
    # CentOS /usr/share/syslinux/
    foreach my $dir (qw(/usr/lib/syslinux/ /usr/share/syslinux/)) {
      if (find_syslinux_files($dir)) {
        $opts{'syslinux'} = $dir;
        last;
      }
    }
  }
  delete $opts{'syslinux'} unless (find_syslinux_files($opts{'syslinux'}));
  die "Must specify useable syslinux utlities path. e.g. /usr/lib/syslinux/\n"
    unless (
      (exists($opts{'syslinux'}) and
      -r $opts{'syslinux'} and -d $opts{'syslinux'}) and
      (exists($opts{'menu_c32'}) and -r $opts{'menu_c32'}) and
      (exists($opts{'mbr_bin'}) and -r $opts{'mbr_bin'})
    );
}

my $CWD = File::Spec->rel2abs(File::Spec->curdir()); # getcwd() # use Cwd;
# Build up the remastered image name if not given.
my $Remaster_base = shift;
unless ($Remaster_base) {
  (my $filename, my $path) = fileparse($Switchvox_iso);
  $filename =~ s/_?dvd//; # remove the _dvd in the filename
  $filename =~ s/\.iso/_usb/; # remove the extension and add '_usb'

  $filename .= "_".lc($opts{'profile'})
    if (exists($opts{'profile'}) and $opts{'profile'});
  $filename .= "_tools"
    if ((exists($opts{'tools'}) and $opts{'tools'}) or !exists($opts{'tools'}));

  #$Remaster_base = File::Spec->catfile($path, $filename);
  $Remaster_base = $filename;
  $opts{'remaster-root'} = File::Spec->catfile($CWD, $Remaster_base);
}
else {
  $opts{'remaster-root'} = File::Spec->rel2abs($Remaster_base);
}

# Get Switchvox build version from ISO file
my $version = fileparse($Switchvox_iso);
$version =~ s/switchvox-?//;
$version =~ s/smb|soho//;
$version =~ s/_?dvd//;
$version =~ s/\.iso//;
$version =~ s/unlimited//;
$version =~ s/-|_//g;
$opts{'swvx_version'} = $version;
my $Template_switchvox_label = <<EOF;
label switchvox#label#
  MENU LABEL ^Switchvox Build $version #menu#
  menu default
  text help
    WARNING: This will REFORMAT your hard drive
  endtext
  kernel #kernel#
  append text reboot=b pci-nommconf method=#method# initrd=#init# ks=#ks#
EOF

undef $version;

$opts{'timeout'} = $Default_Timeout
  unless ( exists($opts{'timeout'}) and defined($opts{'timeout'}) );
$opts{'timezone'} = "" unless ( exists($opts{'timezone'}) );
$opts{'tools'} = 1 unless ( exists($opts{'tools'}) );
$opts{'root'} = 0 unless ( exists($opts{'root'}) );
$opts{'poweroff'} = 0 unless ( exists($opts{'poweroff'}) );
$opts{'reboot'} = 0 unless ( exists($opts{'reboot'}) );
printf(
  "\nSwitchvox Build: %s\nOutput Basename: %s\nOutput Basepath: %s\n".
  "Output Formats: %s\n".
  "Using:\n".
  "  tools:%i  root:%i  poweroff:%i  reboot:%i\n".
  "  Loop = %s\n  Timeout = %i\n  Timezone = %s\n\n",
  $opts{'swvx_version'}, $Remaster_base, $opts{'remaster-root'},
  join(" & ", @{$opts{'output'}}),
  $opts{'tools'}, $opts{'root'}, $opts{'poweroff'}, $opts{'reboot'},
  ($opts{'loop-dev'} ? "'".$opts{'loop-dev'}."'" : "none"), $opts{'timeout'},
  ($opts{'timezone'} ? "'".$opts{'timezone'}."'" : "none")
);

my $COPY;
# setup options to copy recursively, de-reference symlinks,
# and not preserve permissions/owner.  check for rsync first
chomp($COPY = `which rsync`);
if ($COPY ne "") {
  # add in the arguments for rsync
  $COPY .= " -rLPD ";
} else {
  # if rsync isn't available, assume cp is always available.
  chomp($COPY = `which cp`);
  $COPY .= " -LR ";
}

my $Staging_Base="swvx_usb.";
my $dir_staging = tempdir($Staging_Base."XXXXXX", TMPDIR => 1);
my @syslinux_labels;
my $Images_root = "images";
my $Kickstart = "ks.cfg";

sub abort(;$$) {
 my $msg; $msg = shift or $msg = "";
 my $status; $status = shift or $status = 1;

  system("rm -rf ".$dir_staging) if ($status == 0);
  print $msg."\n" if (defined $msg and $msg);
  chdir $CWD;
  exit $status;
}

# /img/: images/ syslinux/
# /img/images/: tools/ switchvox/
# /img/images/tools/: hdd/
# /tmp/: iso/ mnt/ ks/
system('mkdir -p '.
  File::Spec->catfile($dir_staging, "img", $Images_root, 'switchvox').' '.
  File::Spec->catfile($dir_staging, "tmp/iso").' '.
  File::Spec->catfile($dir_staging, "tmp/mnt").' '.
  File::Spec->catfile($dir_staging, "tmp/ks").' '.
  File::Spec->catfile($dir_staging, "img/syslinux")
);
abort("Could not setup staging directory structure") if (($? >> 8) != 0);

sub add_tools() {
  my $TOOLS_ROOT =
    "http://example.internal/public/Switchvox/Tools/";
  my $dir_tools = File::Spec->catfile(
    $dir_staging, "img", $Images_root, "tools"
  );
  my $dir_hdd = File::Spec->catfile($dir_tools, "hdd");
  my $path_tools = File::Spec->catfile("/", $Images_root, "tools");
  my $path_hdd = File::Spec->catfile($path_tools, "hdd");

  system('mkdir -p '.$dir_hdd);
  abort("Could not setup tools directory structure") if (($? >> 8) != 0);

  # Get memtest
  chdir $dir_tools;
  my $memtest = "memtest";
  system('wget '.$TOOLS_ROOT.$memtest.".bin -O ".$memtest);
  abort("Could not download memtest") if (($? >> 8) != 0);
  # TODO: md5sum check?
  $memtest = File::Spec->catfile($path_tools, $memtest);
  my $tools_label = <<EOF;
label memtest
  MENU LABEL ^Memtest
  text help
    Memtest86+ 5.01
  endtext
  kernel $memtest
EOF

  push(@syslinux_labels, $tools_label);

  # Get hdd-tools
  chdir $dir_hdd;
  my $hdd = "hdd.tar";
  system('wget '.$TOOLS_ROOT.$hdd." -O ".$hdd);
  abort("Could not download hdd tools") if (($? >> 8) != 0);
  # TODO: md5sum check?
  $hdd = File::Spec->catfile($dir_hdd, $hdd);
  system('tar -xf '.$hdd.' -C '.$dir_hdd);
  abort("Could not extract hdd tools") if (($? >> 8) != 0);
  # TODO: md5sum check?
  system('rm -f '.$hdd);
  my $kernel = File::Spec->catfile($path_hdd, "vmlinuz");
  my $initrd = File::Spec->catfile($path_hdd, "core.gz");
  $tools_label = <<EOF;
label hdd
  MENU LABEL HDD ^Utilities
  text help
    Provides fsck, S.M.A.R.T. tests, shred, and more
  endtext
  kernel $kernel
  initrd $initrd
  append quiet norestore superuser ghes.disable=1 vmalloc=256M loglevel=3
EOF

  push(@syslinux_labels, $tools_label);
  chdir $CWD;
}

sub extract_switchvox_iso() {
  my $iso_mount = File::Spec->catfile($dir_staging, "tmp/mnt");
  my $iso_work_dir = File::Spec->catfile($dir_staging, "tmp/iso");

  # begin the real work
  print "Extracting needed contents of ISO to $iso_work_dir\n";

  system("mount -o users -o loop $Switchvox_iso $iso_mount");
  abort("Failed to mount ISO, are you running as root?") if (($? >> 8) != 0);

  local *my_abort = sub {
    system("umount $iso_mount");
    abort(@_);
  };
  my @files;
  chomp(my $isolinux_dir =
    `find $iso_mount -path '*[is][sy][os]linux'|tr '\n' ' '`
  );
  push(@files, $isolinux_dir);
  # Copy the isolinux or syslinux directory to the working directory for edits
  # Copy the kernel and initrd image, which will be in that isolinux folder
  my $boot_path = File::Spec->catfile($iso_mount, "isolinux");
  chomp(my $kernel = `find $boot_path -name 'vmlinuz'|head -n1`);
  push(@files, $kernel);
  chomp(my $initrd = `find $boot_path -name 'initrd.img'|head -n1`);
  push(@files, $initrd);
  chomp(my $ks_file =  `find $iso_mount -name '$Kickstart'`);
  push(@files, $ks_file);
  chomp(my $ks_files =  `find $iso_mount -name 'ks*.cfg'|tr '\n' ' '`);
  push(@files, $ks_files);

  system($COPY.join(' ', @files).' '.$iso_work_dir);
  my_abort("Failed to copy ISO files to staging directory") if (($? >> 8) != 0);
  system("sync"); # Flush writes to disk before continuing.
  system("umount $iso_mount");
  print "Finished extracting ISO\n";
}

sub remaster_switchvox_kickstart() {
  # Write out the selected kickstart as ks.cfg, then write out each
  # profile as ks-<profile>.cfg
  # Stuff the current configuration into the profiles hash
  foreach my $o ( qw(root poweroff reboot timezone) ) {
    $profiles{''}->{$o} = $opts{$o};
  }

  # Now work through the profiles and write a kickstart for each one.
  my $dir_ks = File::Spec->catfile($dir_staging, "tmp/ks/");
  my $dir_iso = File::Spec->catfile($dir_staging, "tmp/iso");
  my $path_img = File::Spec->catfile('/', $Images_root, 'switchvox');
  chomp(my $ks_raw =  `find $dir_iso -name '$Kickstart'`);

  # Adjust partitioning to not delete or use the thumbdrive,
  # and to handle new/wiped/unformatted hard-drives
  my $command = "sed -i -e '".
    's#cdrom#harddrive  --partition=sdb1 --dir='.$path_img.'#;'.
    's#^clearpart#zerombr yes\nclearpart#;'.
    's#^clearpart #ignoredisk --drives=sdb\nclearpart '.
      '--drives=sda --initlabel #;'.
    's#^bootloader.*#bootloader --location=mbr --driveorder=sda#g;'.
    "' ".$ks_raw;
  system($command);
  abort("Failed to initially modify Kickstart file") if (($? >> 8) != 0);
  system('sync');

  foreach my $p ( keys(%profiles) ) {
    # set-up the name of the file
    my $ks = $Kickstart;
    $ks = "ks-".lc($p).".cfg" if ($p);
    $ks = File::Spec->catfile($dir_ks, $ks);

    # copy the base kickstart file to the new name
    system($COPY.$ks_raw.' '.$ks);
    abort("Failed to copy kickstart file to staging") if (($? >> 8) != 0);
    system('sync');

    # Now modify the file in place
    # set the timezone, if specified
    if (exists($profiles{$p}->{'timezone'}) and $profiles{$p}->{'timezone'}) {
      system("sed -i -e '".
        's%^timezone.*$%%; '.
        's%bootloader%timezone '.$profiles{$p}->{'timezone'}.'\nbootloader%;'.
        "' ".$ks
      );
      abort("Failed to update kickstart file timezone") if (($? >> 8) != 0);
    }
    if (exists($profiles{$p}->{'poweroff'}) and $profiles{$p}->{'poweroff'}) {
      system("sed -i -e '".
        's%^poweroff.*$%%;s%^reboot.*$%%; '.
        's/%packages/poweroff\n%packages/'.
        "' ".$ks
      );
      abort("Failed to update kickstart file for poweroff") if (($? >> 8) != 0);
    }
    if (exists($profiles{$p}->{'reboot'}) and $profiles{$p}->{'reboot'}) {
      system("sed -i -e '".
        's%^poweroff.*$%%;s%^reboot.*$%%; '.
        's/%packages/reboot\n%packages/'.
        "' ".$ks
      );
      abort("Failed to update kickstart file for reboot") if (($? >> 8) != 0);
    }
    if (exists($profiles{$p}->{'root'}) and $profiles{$p}->{'root'}) {
      system("sed -i -e '".
        's#/sbin/chkconfig sshd .*##;'.
        's#^rootpw.*$##;s#bootloader#rootpw blah\nbootloader#;'.
        's#perl -i -npe .*#/sbin/chkconfig sshd on\n'.
          'sed -i -e "s|^UsePAM yes$|UsePAM no|" /etc/ssh/sshd_config#;'.
        "' ".$ks
      );
      abort("Failed to enable root in kickstart file") if (($? >> 8) != 0);
    }
  }
  system('sync');
}

sub remaster_switchvox() {
  extract_switchvox_iso();
  remaster_switchvox_kickstart();

  my $dir_iso = File::Spec->catfile($dir_staging, "tmp/iso");
  my $dir_swvx = File::Spec->catfile(
    $dir_staging, "img", $Images_root, "switchvox"
  );
  my $ks = File::Spec->catfile($dir_staging, "tmp/ks", $Kickstart);
  my @files = ($Switchvox_iso, $ks);
  chomp(my $kernel = `find $dir_iso -name 'vmlinuz'|head -n1`);
  push(@files, $kernel);
  chomp(my $initrd = `find $dir_iso -name 'initrd.img'|head -n1`);

  # crack open the initrd.img, and do any driver fixes needed.
  my $dir_init = File::Spec->catfile($dir_staging, "tmp/mnt");
  chdir $dir_init;
  system("gzip -dc $initrd 2>/dev/null | cpio -iud 2>/dev/null");
  if (($? >> 8) != 0) {
    system("cpio -iud < $initrd");
    abort("failed to extract initrd image") if (($? >> 8) != 0);
  }

  # Workaround for an anaconda installer issue, credit shaun
  my $raid_driver =
    File::Spec->catfile($dir_init, "drivers/disk/aacraid_dd.img");
  if (-e $raid_driver) {
    my $dd = File::Spec->catfile($dir_init, "dd.img");
    system($COPY.$raid_driver.' '.$dd);
    abort("failed to copy raid driver into initrd") if (($? >> 8) != 0);
  }

  # Copy all of the kickstart files, or only the specified one
  if (exists($opts{'all-kickstarts'}) and $opts{'all-kickstarts'}) {
    push(@files, File::Spec->catfile($dir_staging, "tmp/ks/ks*.cfg") );
    system($COPY.File::Spec->catfile($dir_staging, "tmp/ks/*").' '.$dir_init);
  }
  else {
    system($COPY.$ks.' '.$dir_init);
  }
  abort("failed to copy kickstart file(s) into initrd") if (($? >> 8) != 0);

  # Rebundle the initrd.img
  my $dir_tmp = File::Spec->catfile($dir_staging, "tmp/");
  my $new_initrd = File::Spec->catfile($dir_tmp, "initrd.img");
  push(@files, $new_initrd);
  system("find ./ | cpio -H newc -o > ".$new_initrd);
  abort("failed to create updated initrd") if (($? >> 8) != 0);
  chdir $dir_tmp;
  system("sync;gzip -q ".$new_initrd."");
  abort("failed to compress updated initrd") if (($? >> 8) != 0);
  system("sync;mv ".$new_initrd.".gz ".$new_initrd);
  abort("failed to rename initrd") if (($? >> 8) != 0);
  chdir $CWD;

  system('sync;'.$COPY.join(' ', @files).' '.$dir_swvx);
  abort("failed to copy files to image directory") if (($? >> 8) != 0);
  $dir_init = File::Spec->catfile($dir_init, "*");
  system("rm -rf ".$dir_init);
  abort("Couldn't clean up extracted initrd") if (($? >> 8) != 0);

  # Generate the syslinux label for switchvox
  my $dir_cfg = File::Spec->catfile("/", $Images_root, "switchvox");
  my $method_path = 'hd:sdb1:'.$dir_cfg;
  $kernel = File::Spec->catfile($dir_cfg, "vmlinuz");
  my $init = File::Spec->catfile($dir_cfg, "initrd.img");
  $ks = File::Spec->catfile($dir_cfg, $Kickstart);

  # Handle all the generic values in the template
  my $switchvox_label = $Template_switchvox_label;
  $switchvox_label =~ s/#kernel#/$kernel/;
  $switchvox_label =~ s/#init#/$init/;
  $switchvox_label =~ s/#method#/$method_path/;

  unless (exists($opts{'all-kickstarts'}) and $opts{'all-kickstarts'}) {
    # handle the base case of only one kickstart here
    # Use the kickstart file embedded in the image in this case for simplicity
    $ks = 'file:/'.$Kickstart;
    $switchvox_label =~ s/ #menu#//;
    $switchvox_label =~ s/#label#//;
    $switchvox_label =~ s/#ks#/$ks/;
    push(@syslinux_labels, $switchvox_label);
  }
  else {
    # write out a label for each kickstart, only menu, label, and ks will change
    $switchvox_label =~ s/\^//;
    $switchvox_label =~ s/\s*menu default//i;

    foreach my $profile ( sort(keys(%profiles)) ) {
      my $profile_label = $switchvox_label;
      $ks = File::Spec->catfile($dir_cfg, "ks-".lc($profile).".cfg");
      $ks = File::Spec->catfile($dir_cfg, "ks.cfg") unless ($profile);
      # Use the kickstarts on the thumbdrive here instead of embedded
      # makes it easier to change on the fly if needed.
      $ks = 'hd:sdb1:'.$ks;
      my $menu_label = "\n  menu default";
      $menu_label = '- ^'.uc($profile) if ($profile);
      $profile_label =~ s/#menu#/$menu_label/;
      $profile_label =~ s/#label#/-$profile/ if ($profile);
      $profile_label =~ s/#label#//; # If profile isn't valid, clear the holder
      $profile_label =~ s/#ks#/$ks/;

      push(@syslinux_labels, $profile_label);
    }
  }
}

sub write_syslinux_cfg() {
  my $cfg_file = "syslinux.cfg";
  my $cfg_base = File::Spec->catfile($dir_staging, "img/syslinux");
  my $cfg_stage = File::Spec->catfile($cfg_base, $cfg_file);

  my %syslinux_general;
  $syslinux_general{'menu title'} = "USB Switchvox Tools and Installer";
  $syslinux_general{'menu autoboot'} =
    "Booting Local HDD installation in # seconds";
  $syslinux_general{'ui'} = "menu.c32";
  $syslinux_general{'default'} = "menu.c32";
  $syslinux_general{'ontimeout'} = $opts{'ontimeout'};
  $syslinux_general{'prompt'} = 1;
  $syslinux_general{'timeout'} = $opts{'timeout'};
  if ($Output_Image) {
    system($COPY.$opts{'menu_c32'}." ".$cfg_base);
    abort("Couldn't copy syslinux utilities to staging") if (($? >> 8) != 0);
  }

  my $syslinux_cfg_label = <<EOF;
label bootlocal
  MENU LABEL ^Local HDD installation
  LOCALBOOT 0x80 0
EOF

  push(@syslinux_labels, $syslinux_cfg_label);

  open(FH, ">".$cfg_stage)
    or abort("Couldn't open the syslinux.cfg file for writing");
  # loop through 'general' hash and write out '$key $value' to syslinux.cfg
  foreach my $key (keys %syslinux_general) {
    print FH $key." ".$syslinux_general{$key}."\n";
  }
  print FH "\n";
  # loop through 'labels' array and write out the individual labels
  foreach my $label (@syslinux_labels) {
    print FH $label."\n\n";
  }
  close(FH);
}

sub create_usb_img() {
  # Get size of img/ directory, and make heads, cylinders, sectors big enough
  # to accomodate
  # 63 sectors is default on most modern hard drives
  my $sectors = 63;
  # 1023 cylinders randomly required to work correctly in testing
  my $cylinders = 1023;
  # 512 bytes is normal default in most modern applications
  my $bytes = 512;
  my $base = $sectors * $cylinders * $bytes;

  # get size of img contents
  my $dir_image = File::Spec->catfile($dir_staging, "img");
  chomp(my $size_contents = `du -bs $dir_image|awk '{print \$1}'`);
  abort("Couldn't get size of image contents") unless ($size_contents);

  # Starting point just under the current required size
  my $heads = 47;
  while ($size_contents > ($heads * $base) and ($heads < 255)) {
    $heads++;
  }
  abort("Created image too large") if ($heads > 255);

  my $size_img = $base * $heads;
  my $img = $opts{'remaster-root'}.".img";

  print "\n\nCreating $img\n\n";
  system("dd if=/dev/zero of=".$img.
    " bs=64K count=".(int $size_img / (64 * 1024) + 1)
  );
  abort("Could not create image file") if (($? >> 8) != 0);
  system("losetup ".$opts{'loop-dev'}." ".$img);
  abort("Could not setup loop device") if (($? >> 8) != 0);

  local *my_abort = sub {
    system("sync;losetup -d ".$opts{'loop-dev'});
    abort(@_);
  };

  system("parted --script ".$opts{'loop-dev'}." mklabel msdos");
  my_abort("Could not create partition table") if (($? >> 8) != 0);
  system("dd if=".$opts{'mbr_bin'}." of=".$opts{'loop-dev'});
  my_abort("Could not copy mbr.bin") if (($? >> 8) != 0);

  system("cat << EOF | fdisk ".$opts{'loop-dev'}." >/dev/null 2>&1
n
p
1


t
0b
a
1
p
w
EOF
");
  my $check = 'fdisk -l '.$opts{'loop-dev'};
  $check = `$check`;
  my_abort("Error setting up partitions in image")
    unless ($check =~ /W95 FAT32|FAT16/);
  print $check."\n";

  system("sync;losetup -d ".$opts{'loop-dev'});
  abort("Could not tear down loop device") if (($? >> 8) != 0);
  my $command = 'fdisk -l '.$img.' | tail -n1 |'.
    "sed -e 's|\\*||;s|\\s\\s*| |g' | cut -d ' ' -f2-3";
  chomp(my $start_sector = `$command`);
  abort("Could not determine start & end sectors") if (($? >> 8) != 0);
  my $end = 0;
  ($start_sector, $end) = split(/ /, $start_sector);
  # <sector start> * <sector size in bytes>
  my $offset = $start_sector * $bytes;
  $end = $end * $bytes; # convert to bytes
  print "using range: $offset - $end (bytes) for setting up partition\n";
  $command = "losetup -o ".$offset." --sizelimit ".$end." ".
    $opts{'loop-dev'}." ".$img;
  if (`losetup -h 2>&1` !~ '--sizelimit') {
    $command = "losetup -o ".$offset." ".$opts{'loop-dev'}." ".$img;
  }
  #print "create_usb_image:: Command: $command\n";
  system($command);
  abort("Could not setup 2nd partition on loop device") if (($? >> 8) != 0);
  system("mkfs -t vfat ".$opts{'loop-dev'});
  my_abort("Could not create filesystem in image") if (($? >> 8) != 0);
      #system("df -h | grep $opts{'loop-dev'}");
  my $dir_mnt = File::Spec->catfile($dir_staging, "tmp/mnt");
  system("mount -t vfat -o group -o users ".$opts{'loop-dev'}." ".$dir_mnt);
  my_abort("Could not mount filesystem in image") if (($? >> 8) != 0);

  local *mnt_abort = sub {
    system("sync;umount ".$dir_mnt);
    my_abort(@_);
  };

  my $dir_img = File::Spec->catfile($dir_staging, "img/*");
  system('sync;'.$COPY.$dir_img.' '.$dir_mnt);
  mnt_abort("Could not copy contents to image") if (($? >> 8) != 0);
  system("sync;".
    "syslinux --directory /syslinux --stupid --install ".$opts{'loop-dev'}
  );
  mnt_abort("image syslinux installation failed") if (($? >> 8) != 0);
  system("sync");

  # Wrap up the image
  system("sync;umount ".$dir_mnt);
  my_abort("Could not unmount image") if (($? >> 8) != 0);
  system("sync;losetup -d ".$opts{'loop-dev'});
  abort("Could not tear down partition loop device") if (($? >> 8) != 0);
  (my $filename, my $path) = fileparse($img);
  chdir $path;
  system("sync;md5sum ".$filename.' > '.$filename.'.md5');
  print "\n\nFinished creating $img\n\n";
  system("sync");
  chdir $CWD;
}

sub create_archives() {
  my $dir_img = File::Spec->catfile($dir_staging, "img/");
  chdir $dir_img;

  print "\n";
  foreach my $fmt ( @{ $opts{'output'} } ) {
    next if (lc($fmt) eq "img");
    next unless (exists($outputs{$fmt}) and $outputs{$fmt});

    # Handle creating the archives
    my $archive = $opts{'remaster-root'}.".".lc($fmt);
    my $cmd = $outputs{$fmt};
    $cmd =~ s/#archive#/$archive/;
    $cmd =~ s/#files#/.\//;
    $cmd =~ s/#x#/menu.c32/;

    print "\ncreating $archive\n";
    system($cmd);
    abort("Could not create $fmt archive") if (($? >> 8) != 0);
    (my $filename, my $path) = fileparse($archive);
    chdir $path;
    system("sync;md5sum ".$filename.' > '.$filename.'.md5');
    print "\nFinished creating $archive\n";
  }
  system("sync");
  chdir $CWD;
}

# Setup the remastered content in the staging directory first
print "\n\nBeginning image remastering\n\n";
remaster_switchvox();
add_tools() if ( exists($opts{'tools'}) and $opts{'tools'} );
write_syslinux_cfg();
print "\n\nFinished remastering and configuring the image\n\n";

# Then create the output formats as needed.
if ($Output_Image) {
  create_usb_img();
}
create_archives();
abort("Finished", 0);


__END__

=pod

=head1 NAME

switchvox-usb - Switchvox Installer - USB Image utility Usage

=head1 SYNOPSIS

switchvox-usb.pl [options] <input iso> [output base-name]

 Options:
   --output, -o     specify output formats to generate:
                      img, tarball, tgz, zip
   --profile, -p    configuration profile to generate against:
                      default, est, cst, pst, Ops, Eng
   --loop-dev, -l   specify an alternative loop device
   --syslinux       specify the syslinux install path

   --timeout        specify the syslinux menu timeout
   --tools          include additional troubleshooting tools (default)
   --no-tools       override inclusion of tools

   --timezone       specify the timezone to preselect for switchvox
   --root           allow root login once installed
   --no-root        override allowing root login (default)
   --poweroff       power off the system upon completion of install
   --no-poweroff    override powering off the system (default)
   --reboot         reboot the system upon completion of install
   --no-reboot      override rebooting the system (default)

 <input iso> should be an existing Switchvox install ISO
 [output base-name] is optional and will be the name of the output files
    with the addition of their respective suffixes.

=head1 DESCRIPTION

B<This program> will accept a Switchvox ISO file and generate a disk
image or tarball with a modified kickstart that supports installing from
a hard-drive or usb device.

=cut
