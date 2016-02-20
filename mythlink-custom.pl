#!/usr/bin/perl -w
#
# Creates custom symlinks to MythTV recordings using human-readable filenames.
#
# The full contents of the link name are determined by the availability of various recording
# metadata:
#
#  - subtitle
#  - season number
#  - episode number
#  - original year
#  - original transmission date from description (radio)
#  - programme title
#  - channel name
#
#
# recordings-symlinks
# |-- Childrens
# |    |-- CBeebies Bedtime Story
# |    |    +- %S
# |    +-- %T
# |         +- S%ss%ep %S
# |-- Movies
# |    |-- BBC
# |    |    +- %T (%oY)
# |    +-- Commercial
# |         +- %T (%oY)
# |-- Radio
# |    +-- %T
# |         +- %T - SxxE%ep %S (yyyy-mm)
# |-- TV
#      +-- %T
#           |- S%ssE%ep %S
#           |- S%ssE%ep %T
#           |- %S
#           +- %T
#
#
# See --help for general instructions.
#
# Automatically detects database settings from mysql.txt, and loads
# the mythtv recording directory from the database (code from nuvexport).
#
# Based on mythlink.pl from MythTV 0.27.5
#
# @license   GPL
#

# Includes
    use DBI;
    use Getopt::Long;
    use File::Path;
    use File::Basename;
    use File::Find;
    use MythTV;

# Some variables we'll use here
    our ($dest, $chanid, $starttime, $filename);
    our ($usage, $live, $deleted);
    our ($dseparator, $dreplacement, $separator, $replacement);

    our ($db_host, $db_user, $db_name, $db_pass, $video_dir, $verbose);
    our ($hostname, $dbh, $sh, $q, $count, $base_dir);

    our (@radio_channels, @commfree_channels, @childrens_programmes);
    our %mname_to_mdigits;

# Default separator character
    $dseparator = '-';
# Default replacement character
    $dreplacement = '-';

# Provide default values for GetOptions
    $separator   = $dseparator;
    $replacement = $dreplacement;
    $maxlength   = -1;

# Radio and commercial-free channel channums (UK Freeview/Freesat/VM cable config)
    @radio_channels    = (901,902,903,904,905,906,907,908,909,910,911,912);
    @commfree_channels = (101,102,106,107,601,605,701,702,862,990,991,992,993,994,995);

# Children's programmes
    @childrens_programmes = (
        'CBeebies Bedtime Story',
        'Clangers',
        'Danger Mouse',
        'Hey Duggee',
        'In the Night Garden',
        'Thunderbirds Are Go',
    );

# Hash to convert between month names and month digits
    %mname_to_mdigits = (
        'January'   => '01',
        'February'  => '02',
        'March'     => '03',
        'April'     => '04',
        'May'       => '05',
        'June'      => '06',
        'July'      => '07',
        'August'    => '08',
        'September' => '09',
        'October'   => '10',
        'November'  => '11',
        'December'  => '12',
    );

# Load the cli options
    GetOptions('link-directory=s'             => \$dest,
               'chanid=s'                     => \$chanid,
               'starttime=s'                  => \$starttime,
               'filename=s'                   => \$filename,
               'live'                         => \$live,
               'deleted'                      => \$deleted,
               'separator=s'                  => \$separator,
               'replacement=s'                => \$replacement,
               'verbose'                      => \$verbose,
               'usage|help'                   => \$usage,
              );

# Print usage
    if ($usage) {
        print <<EOF;
$0 usage:

options:

--link-directory [directory]

    Specify the directory for the links.  If no pathname is given, links will
    be created in the show_names directory inside of the current mythtv data
    directory on this machine.  eg:

    /var/video/show_names/

    WARNING: ALL symlinks within the link directory and its
    subdirectories (recursive) will be removed.

--chanid chanid

    Create a link only for the specified recording file. Use with --starttime
    to specify a recording. This argument may be used with the event-driven
    notification system's "Recording started" event or in a post-recording
    user job.

--starttime starttime

    Create a link only for the specified recording file. Use with --chanid
    to specify a recording. This argument may be used with the event-driven
    notification system's "Recording started" event or in a post-recording
    user job.

--filename absolute_filename

    Create a link only for the specified recording file. This argument may be
    used with the event-driven notification system's "Recording started" event
    or in a post-recording user job.

--live

    Include live tv recordings.

    default: do not link live tv recordings

--deleted

    Include deleted recordings.

    default: do not link deleted recordings

--separator

    The string used to separate sections of the link name.  Specifying the
    separator allows trailing separators to be removed from the link name and
    multiple separators caused by missing data to be consolidated. Indicate the
    separator character in the format string using either a literal character
    or the \%- specifier.

    default:  '$dseparator'

--replacement

    Characters in the link name which are not legal on some filesystems will
    be replaced with the given character

    illegal characters:  \\ : * ? < > | "

    default:  '$dreplacement'

--verbose

    Print debug info.

    default:  No info printed to console

--help
--usage

    Show this help text.

EOF
        exit;
    }

# Ensure --chanid and --starttime were specified together, if at all
    if ((defined($chanid) or defined($starttime)) and
        !(defined($chanid) and defined($starttime))) {
        die "The arguments --chanid and --starttime must be used together.\n";
    }

# Check the separator and replacement characters for illegal characters
    if ($separator =~ /(?:[\/\\:*?<>|"])/) {
        die "The separator cannot contain any of the following characters:  /\\:*?<>|\"\n";
    }
    elsif ($replacement =~ /(?:[\/\\:*?<>|"])/) {
        die "The replacement cannot contain any of the following characters:  /\\:*?<>|\"\n";
    }

# Escape where necessary
    our $safe_sep = $separator;
        $safe_sep =~ s/([^\w\s])/\\$1/sg;
    our $safe_rep = $replacement;
        $safe_rep =~ s/([^\w\s])/\\$1/sg;

# Get the hostname of this machine
    $hostname = `hostname`;
    chomp($hostname);

# Connect to mythbackend
    my $Myth = new MythTV();

# Connect to the database
    $dbh = $Myth->{'dbh'};
    END {
        $sh->finish  if ($sh);
    }

    my $sgroup = new MythTV::StorageGroup();

# Get our base location
    $base_dir = $sgroup->FindRecordingDir('show_names');
    if ($base_dir eq '') {
        $base_dir = $sgroup->GetFirstStorageDir();
    }

# Link destination
# Double-check the destination
    $dest ||= "$base_dir/show_names";
# Alert the user
    vprint("Link destination directory:  $dest");
# Create nonexistent paths
    unless (-e $dest) {
        mkpath($dest, 0, 0775) or die "Failed to create $dest:  $!\n";
    }
# Bad path
    die "$dest is not a directory.\n" unless (-d $dest);
# Delete old links/directories unless linking only one recording
    if (!defined($filename) and !defined($chanid)) {
    # Delete any old links
        find sub { if (-l $_) {
                       unlink $_ or die "Couldn't remove old symlink $_: $!\n";
                   }
                 }, $dest;
    # Delete empty directories (should this be an option?)
    # Let this fail silently for non-empty directories
        finddepth sub { rmdir $_; }, $dest;
    }

# Create symlinks for the files on this machine
    my %rows = ();
    if (defined($chanid)) {
        %rows = $Myth->backend_rows('QUERY_RECORDING TIMESLOT '.
                                    "$chanid $starttime");

    }
    else {
        %rows = $Myth->backend_rows('QUERY_RECORDINGS Descending');
    }
    foreach my $row (@{$rows{'rows'}}) {
        my $show = new MythTV::Recording(@$row);
    # Skip LiveTV recordings?
        next unless (defined($live) || $show->{'recgroup'} ne 'LiveTV');
    # Skip Deleted recordings?
        next unless (defined($deleted) || $show->{'recgroup'} ne 'Deleted');
    # File doesn't exist locally
        next unless (-e $show->{'local_path'});
    # Check if this is the file to link if only linking one file
        if (defined($filename)) {
            next unless (($show->{'basename'} eq $filename) or
                         ($show->{'local_path'} eq $filename));
        }
        elsif (defined($chanid)) {
            next unless ($show->{'chanid'} eq $chanid);
            my $recstartts = unix_to_myth_time($show->{'recstartts'});
        # Check starttime in MythTV time format (yyyy-MM-ddThh:mm:ss)
            if ($recstartts ne $starttime) {
            # Check starttime in ISO time format (yyyy-MM-dd hh:mm:ss)
                $recstartts =~ tr/T/ /;
                if ($recstartts ne $starttime) {
                # Check starttime in job queue time format (yyyyMMddhhmmss)
                    $recstartts =~ s/[\- :]//g;
                    next unless ($recstartts eq $starttime);
                }
            }
        }
    # Format the name
        my $name = format_fixed_name($show, $separator ,$replacement);
    # Get a shell-safe version of the filename (yes, I know it's not needed in this case, but I'm anal about such things)
        my $safe_file = $show->{'local_path'};
        $safe_file =~ s/'/'\\''/sg;
        $safe_file = "'$safe_file'";
    # Figure out the suffix
        my ($suffix) = ($show->{'basename'} =~ /(\.\w+)$/);
    # Check the link name's length
        $name = cut_down_name($name, $suffix);
    # Link destination
    # Check for duplicates
        if (($name) and -e "$dest/$name$suffix") {
            if ((!defined($filename) and !defined($chanid)) or
                (! -l "$dest/$name$suffix")) {
                $count = 2;
                $name = cut_down_name($name, ".$count$suffix");
                while (($name) and -e "$dest/$name.$count$suffix") {
                    $count++;
                    $name = cut_down_name($name, ".$count$suffix");
                }
                $name .= ".$count" if (($name));
            } else {
                unlink "$dest/$name$suffix" or die "Couldn't remove ".
                       "old symlink $dest/$name$suffix: $!\n";
            }
        }
        if (!($name)) {
            vprint("Unable to represent recording; maxlength too small.");
            next;
        }
        $name .= $suffix;
    # Create the link
        my $directory = dirname("$dest/$name");
        unless (-e $directory) {
            mkpath($directory, 0, 0775)
                or die "Failed to create $directory:  $!\n";
        }
        symlink $show->{'local_path'}, "$dest/$name"
            or die "Can't create symlink $dest/$name:  $!\n";
        vprint("$dest/$name");
    }

# Check the length of the link name
    sub cut_down_name {
        my $name = shift;
        my $suffix = shift;
        if ($maxlength > 0) {
            my $charsavailable = $maxlength - length($suffix);
            if ($charsavailable > 0) {
                $name = substr($name, 0, $charsavailable);
            }
            else {
                $name = '';
            }
        }
        return $name;
    }

# Print the message, but only if verbosity is enabled
    sub vprint {
        return unless (defined($verbose));
        print join("\n", @_), "\n";
    }

# Return a fixed-format filename for this Recording
    sub format_fixed_name {
        my $self        = shift;
        my $separator   = (shift or '-');
        my $replacement = (shift or '-');
        my $allow_dirs  = 1;
        # Escape where necessary
        my $safe_sep = $separator;
        $safe_sep =~ s/([^\w\s])/\\$1/sg;
        my $safe_rep = $replacement;
        $safe_rep =~ s/([^\w\s])/\\$1/sg;

        # Fixed formats depending on recording type
        my $format;
        # Movies
        if ($self->{'category'} =~ /film|movie/i) {
            if (grep { $self->{'channel'}{'channum'} eq $_ } @commfree_channels ) {
                $format = 'Movies/BBC/%T (%oY)';
            }
            else {
                $format = 'Movies/Commercial/%T (%oY)';
            }
        }
        # Radio
        elsif (grep { $self->{'channel'}{'channum'} eq $_ } @radio_channels ) {
            $format = 'Radio/%T/';
            my $ep;
            if (($ep) = $self->{'description'} =~ m/Episode\s(\d+)\sof\s\d+\./) {
                $ep = "0$ep" if ($ep < 10);
                $format .= "%T - SxxE$ep";
            }
            elsif (($ep) = $self->{'description'} =~ m/(\d+)\/\d+\./) {
                $ep = "0$ep" if ($ep < 10);
                $format .= "%T - SxxE$ep";
            }
            $format .= ' ' if ($ep);

            if ($self->{'subtitle'} ne 'Untitled') {
                $format .= '%S';
            }
            else {
                $format .= '%T';
            }

            my ($m, $y);
            if (($m, $y) = $self->{'description'} =~ m/From (\w+)\s(\d{4})\./) {
                $format .= " ($y-$mname_to_mdigits{$m})";
            }
            elsif (($m, $y) = $self->{'description'} =~ m/Recorded in (\w+)\s(\d{4})/) {
                $format .= " ($y-$mname_to_mdigits{$m})";
            }
        }
        # Childrens
        elsif (grep { $self->{'title'} eq $_ } @childrens_programmes ) {
            $format = 'Childrens/%T/';
            if ($self->{'title'} eq 'CBeebies Bedtime Story') {
                $format .= '%S';
            }
            else {
                $format .= 'S%ssE%ep %S';
            }
        }
        # TV
        else {
            $format = 'TV/%T/';
            $format .= 'S%ss' if $self->{'season'};
            $format .= 'E%ep' if $self->{'episode'};
            $format .= ' ' if ($self->{'season'} or $self->{'episode'});
            if ($self->{'subtitle'} ne 'Untitled') {
                $format .= '%S';
            }
            else {
                $format .= '%T';
            }
        }

        # Recording start/end times
        my ($ssecond, $sminute, $shour, $sday, $smonth, $syear) = localtime($self->{'recstartts'});
        my ($esecond, $eminute, $ehour, $eday, $emonth, $eyear) = localtime($self->{'recendts'});
        # Program start/end times
        my ($spsecond, $spminute, $sphour, $spday, $spmonth, $spyear) = localtime($self->{'starttime'});
        my ($epsecond, $epminute, $ephour, $epday, $epmonth, $epyear) = localtime($self->{'endtime'});
        # Format some fields we may be parsing below
        # Recording start time
        $syear += 1900;
        $smonth++;
        $smonth = "0$smonth" if ($smonth < 10);
        $sday   = "0$sday"   if ($sday   < 10);
        my $meridian = ($shour > 12) ? 'PM' : 'AM';
        my $hour = ($shour > 12) ? $shour - 12 : $shour;
        if ($hour < 10) {
            $hour = "0$hour";
        }
        elsif ($hour < 1) {
            $hour = 12;
        }
        $shour   = "0$shour"   if ($shour < 10);
        $sminute = "0$sminute" if ($sminute < 10);
        $ssecond = "0$ssecond" if ($ssecond < 10);
        # Recording end time
        $eyear += 1900;
        $emonth++;
        $emonth = "0$emonth" if ($emonth < 10);
        $eday   = "0$eday"   if ($eday   < 10);
        my $emeridian = ($ehour > 12) ? 'PM' : 'AM';
        my $ethour = ($ehour > 12) ? $ehour - 12 : $ehour;
        if ($ethour < 10) {
            $ethour = "0$ethour";
        }
        elsif ($ethour < 1) {
            $ethour = 12;
        }
        $ehour   = "0$ehour"   if ($ehour < 10);
        $eminute = "0$eminute" if ($eminute < 10);
        $esecond = "0$esecond" if ($esecond < 10);
        # Program start time
        $spyear += 1900;
        $spmonth++;
        $spmonth = "0$spmonth" if ($spmonth < 10);
        $spday   = "0$spday"   if ($spday   < 10);
        my $pmeridian = ($sphour > 12) ? 'PM' : 'AM';
        my $phour = ($sphour > 12) ? $sphour - 12 : $sphour;
        if ($phour < 10) {
            $phour = "0$phour";
        }
        elsif ($phour < 1) {
            $phour = 12;
        }
        $sphour   = "0$sphour"   if ($sphour < 10);
        $spminute = "0$spminute" if ($spminute < 10);
        $spsecond = "0$spsecond" if ($spsecond < 10);
        # Program end time
        $epyear += 1900;
        $epmonth++;
        $epmonth = "0$epmonth" if ($epmonth < 10);
        $epday   = "0$epday"   if ($epday   < 10);
        my $epmeridian = ($ephour > 12) ? 'PM' : 'AM';
        my $epthour = ($ephour > 12) ? $ephour - 12 : $ephour;
        if ($epthour < 10) {
            $epthour = "0$epthour";
        }
        elsif ($epthour < 1) {
            $epthour = 12;
        }
        $ephour   = "0$ephour"   if ($ephour < 10);
        $epminute = "0$epminute" if ($epminute < 10);
        $epsecond = "0$epsecond" if ($epsecond < 10);
        # Original airdate
        my ($oyear, $omonth, $oday);
        if ($self->{'airdate'} =~ /-/) {
            ($oyear, $omonth, $oday) = split('-', $self->{'airdate'}, 3);
        }
        elsif ($self->{'year'} =~ /^\d{4}$/) {
            $oyear = $self->{'year'};
            $omonth = '00';
            $oday = '00';
        }
        else {
            $oyear  = '0000';
            $omonth = '00';
            $oday   = '00';
        }
        # Season/Episode/InetRef
        my ($season, $episode, $inetref);
        $season = ($self->{'season'} or '');
        $season = "0$season" if ($season && $season < 10);
        $episode = ($self->{'episode'} or '');
        $episode = "0$episode" if ($episode && $episode < 10);
        $inetref = ($self->{'inetref'} or '');

        # Build a list of name format options
        my %fields;
        ($fields{'T'} = ($self->{'title'}       or '')) =~ s/%/%%/g;
        ($fields{'S'} = ($self->{'subtitle'}    or '')) =~ s/%/%%/g;
        ($fields{'R'} = ($self->{'description'} or '')) =~ s/%/%%/g;
        ($fields{'C'} = ($self->{'category'}    or '')) =~ s/%/%%/g;
        ($fields{'U'} = ($self->{'recgroup'}    or '')) =~ s/%/%%/g;
        # Misc
        ($fields{'hn'} = ($self->{'hostname'}    or '')) =~ s/%/%%/g;
        # Channel info
        $fields{'c'}   = $self->{'chanid'};
        ($fields{'cn'} = ($self->{'channel'}{'channum'}  or '')) =~ s/%/%%/g;
        ($fields{'cc'} = ($self->{'channel'}{'callsign'} or '')) =~ s/%/%%/g;
        ($fields{'cN'} = ($self->{'channel'}{'name'}     or '')) =~ s/%/%%/g;
        # Recording start time
        $fields{'y'} = substr($syear, 2);   # year, 2 digits
        $fields{'Y'} = $syear;              # year, 4 digits
        $fields{'n'} = int($smonth);        # month
        $fields{'m'} = $smonth;             # month, leading zero
        $fields{'j'} = int($sday);          # day of month
        $fields{'d'} = $sday;               # day of month, leading zero
        $fields{'g'} = int($hour);          # 12-hour hour
        $fields{'G'} = int($shour);         # 24-hour hour
        $fields{'h'} = $hour;               # 12-hour hour, with leading zero
        $fields{'H'} = $shour;              # 24-hour hour, with leading zero
        $fields{'i'} = $sminute;            # minutes
        $fields{'s'} = $ssecond;            # seconds
        $fields{'a'} = lc($meridian);       # am/pm
        $fields{'A'} = $meridian;           # AM/PM
        # Recording end time
        $fields{'ey'} = substr($eyear, 2);  # year, 2 digits
        $fields{'eY'} = $eyear;             # year, 4 digits
        $fields{'en'} = int($emonth);       # month
        $fields{'em'} = $emonth;            # month, leading zero
        $fields{'ej'} = int($eday);         # day of month
        $fields{'ed'} = $eday;              # day of month, leading zero
        $fields{'eg'} = int($ethour);       # 12-hour hour
        $fields{'eG'} = int($ehour);        # 24-hour hour
        $fields{'eh'} = $ethour;            # 12-hour hour, with leading zero
        $fields{'eH'} = $ehour;             # 24-hour hour, with leading zero
        $fields{'ei'} = $eminute;           # minutes
        $fields{'es'} = $esecond;           # seconds
        $fields{'ea'} = lc($emeridian);     # am/pm
        $fields{'eA'} = $emeridian;         # AM/PM
        # Program start time
        $fields{'py'} = substr($spyear, 2); # year, 2 digits
        $fields{'pY'} = $spyear;            # year, 4 digits
        $fields{'pn'} = int($spmonth);      # month
        $fields{'pm'} = $spmonth;           # month, leading zero
        $fields{'pj'} = int($spday);        # day of month
        $fields{'pd'} = $spday;             # day of month, leading zero
        $fields{'pg'} = int($phour);        # 12-hour hour
        $fields{'pG'} = int($sphour);       # 24-hour hour
        $fields{'ph'} = $phour;             # 12-hour hour, with leading zero
        $fields{'pH'} = $sphour;            # 24-hour hour, with leading zero
        $fields{'pi'} = $spminute;          # minutes
        $fields{'ps'} = $spsecond;          # seconds
        $fields{'pa'} = lc($pmeridian);     # am/pm
        $fields{'pA'} = $pmeridian;         # AM/PM
        # Program end time
        $fields{'pey'} = substr($epyear, 2);# year, 2 digits
        $fields{'peY'} = $epyear;           # year, 4 digits
        $fields{'pen'} = int($epmonth);     # month
        $fields{'pem'} = $epmonth;          # month, leading zero
        $fields{'pej'} = int($epday);       # day of month
        $fields{'ped'} = $epday;            # day of month, leading zero
        $fields{'peg'} = int($epthour);     # 12-hour hour
        $fields{'peG'} = int($ephour);      # 24-hour hour
        $fields{'peh'} = $epthour;          # 12-hour hour, with leading zero
        $fields{'peH'} = $ephour;           # 24-hour hour, with leading zero
        $fields{'pei'} = $epminute;         # minutes
        $fields{'pes'} = $epsecond;         # seconds
        $fields{'pea'} = lc($epmeridian);   # am/pm
        $fields{'peA'} = $epmeridian;       # AM/PM
        # Original Airdate
        $fields{'oy'} = substr($oyear, 2);  # year, 2 digits
        $fields{'oY'} = $oyear;             # year, 4 digits
        $fields{'on'} = int($omonth);       # month
        $fields{'om'} = $omonth;            # month, leading zero
        $fields{'oj'} = int($oday);         # day of month
        $fields{'od'} = $oday;              # day of month, leading zero
        # Season/Episode/Inetref
        $fields{'ss'} = $season;
        $fields{'ep'} = $episode;
        $fields{'in'} = $inetref;

        # Literals
        $fields{'%'}   = '%';
        ($fields{'-'}  = $separator) =~ s/%/%%/g;
        # Make the substitution
        my $keys = join('|', reverse sort keys %fields);
        my $name = $format;
        $name =~ s#/#$allow_dirs ? "\0" : $separator#ge;
        $name =~ s/(?<!%)(?:%($keys))/$fields{$1}/g;
        $name =~ s/%%/%/g;
        # Some basic cleanup for illegal (windows) filename characters, etc.
        $name =~ tr/\ \t\r\n/ /s;
        $name =~ tr/"/'/s;
        $name =~ s/(?:[\/\\:*?<>|]+\s*)+(?=[^\d\s])/$replacement /sg;
        $name =~ s/[\/\\:*?<>|]/$replacement/sg;
        $name =~ s/(?:(?:$safe_sep)+\s*)+(?=[^\d\s])/$separator /sg;
        $name =~ s/^($safe_sep|$safe_rep|\ )+//s;
        $name =~ s/($safe_sep|$safe_rep|\ )+$//s;
        $name =~ s/\0($safe_sep|$safe_rep|\ )+/\0/s;
        $name =~ s/($safe_sep|$safe_rep|\ )+\0/\0/s;
        # Folders
        $name =~ s#\0#/#sg;
        # Return
        return $name;
    }
