# $Id$

package main;

use strict;
use warnings;
use Scalar::Util qw(looks_like_number);
use UConv;

sub Unit_Initialize() {
}

###########################################
# Functions used to make fhem-oneliners more readable,
# but also recommended to be used by modules

sub ReadingsUnit($$@) {
    my ( $d, $n, $default, $lang, $format ) = @_;
    my $ud;
    $default = "" if ( !$default );
    return ""
      if ( !defined( $defs{$d}{READINGS}{$n} ) );

    addToAttrList("unitFromReading");

    my $unitFromReading =
      AttrVal( $d, "unitFromReading",
        AttrVal( "global", "unitFromReading", undef ) );

    # unit defined with reading
    if ( defined( $defs{$d}{READINGS}{$n}{U} ) ) {
        $ud = Unit::GetDetails( $defs{$d}{READINGS}{$n}{U}, $lang );
    }

    # calculate unit from readingname
    elsif ( $unitFromReading && $unitFromReading ne "0" ) {
        $ud = Unit::GetDetailsFromReadingname( $n, $lang );
    }

    return $ud->{"unit"} if ( !$format && defined( $ud->{"unit"} ) );
    return $ud->{"unit_long"}
      if ( $format && $format eq "1" && defined( $ud->{"unit_long"} ) );
    return $ud->{"unit_abbr"}
      if ( $format && $format eq "2" && defined( $ud->{"unit_abbr"} ) );
    return $default;
}

sub ReadingsUnitLong($$@) {
    my ( $d, $n, $default, $lang ) = @_;
    $lang = "en" if ( !$lang );
    return ReadingsUnit( $d, $n, $default, $lang, 1 );
}

sub ReadingsUnitAbbr($$@) {
    my ( $d, $n, $default, $lang ) = @_;
    $lang = "en" if ( !$lang );
    return ReadingsUnit( $d, $n, $default, $lang, 2 );
}

sub ReadingsValUnit($$$@) {
    my ( $d, $n, $default, $lang, $format ) = @_;
    my $v = ReadingsVal( $d, $n, $default );
    my $u = ReadingsUnitAbbr( $d, $n );
    return Unit::GetValueWithUnit( $v, $u, $lang, $format );
}

sub ReadingsValUnitLong($$$@) {
    my ( $d, $n, $default, $lang ) = @_;
    return ReadingsValUnit( $d, $n, $default, $lang, 1 );
}

################################################################
# Functions used by modules.

sub setReadingsUnit($$@) {
    my ( $hash, $rname, $unit ) = @_;
    my $name = $hash->{NAME};
    my $unitDetails;

    return "Cannot assign unit to undefined reading $rname for device $name"
      if ( !$hash->{READINGS}{$rname}
        || !defined( $hash->{READINGS}{$rname} ) );

    # check unit database for unit_abbr
    if ($unit) {
        $unitDetails = Unit::GetDetails($unit);
    }

    # find unit based on reading name
    else {
        $unitDetails = Unit::GetDetailsFromReadingname($rname);
        return
          if ( !$unitDetails || !defined( $unitDetails->{"unit_abbr"} ) );
    }

    return
"$unit is not a registered unit abbreviation and cannot be assigned to reading $name: $rname"
      if ( !$unitDetails || !defined( $unitDetails->{"unit_abbr"} ) );

    if (
        !$unit
        && ( !defined( $hash->{READINGS}{$rname}{U} )
            || $hash->{READINGS}{$rname}{U} ne $unitDetails->{"unit_abbr"} )
      )
    {
        $hash->{READINGS}{$rname}{U} = $unitDetails->{"unit_abbr"};
        return "Set auto-detected unit for reading $name $rname: "
          . $unitDetails->{"unit_abbr"};
    }

    $hash->{READINGS}{$rname}{U} = $unitDetails->{"unit_abbr"};
    return;
}

sub removeReadingsUnit($$) {
    my ( $hash, $rname ) = @_;
    my $name = $hash->{NAME};

    return "Cannot remove unit from undefined reading $rname for device $name"
      if ( !$hash->{READINGS}{$rname}
        || !defined( $hash->{READINGS}{$rname} ) );

    if ( defined( $hash->{READINGS}{$rname}{U} ) ) {
        my $u = $hash->{READINGS}{$rname}{U};
        delete $hash->{READINGS}{$rname}{U};
        return "Removed unit $u from reading $rname of device $name";
    }

    return;
}

sub getMultiValStatus($$;$$) {
    my ( $d, $rlist, $lang, $format ) = @_;
    my $txt = "";

    if ( !$format ) {
        $format = "-1";
    }
    else {
        $format--;
    }

    foreach ( split( /\s+/, $rlist ) ) {
        $_ =~ /^(\w+):?(\w+)?$/;
        my $v = (
            $format > -1
            ? ReadingsValUnit( $d, $1, "", $lang, $format )
            : ReadingsVal( $d, $1, "" )
        );
        my $n = ( $2 ? $2 : Unit::GetShortReadingname($1) );

        if ( $v ne "" ) {
            $txt .= " " if ( $txt ne "" );
            $txt .= "$n: $v";
        }
    }

    return $txt;
}

################################################################
#
# Wrappers for commonly used core functions in device-specific modules.
#
################################################################

sub readingsUnitSingleUpdate($$$$$) {
    my ( $hash, $reading, $value, $unit, $dotrigger ) = @_;
    readingsUnitBeginUpdate($hash);
    my $rv = readingsUnitBulkUpdate( $hash, $reading, $value, $unit );
    readingsUnitEndUpdate( $hash, $dotrigger );
    return $rv;
}

sub readingsUnitSingleUpdateIfChanged($$$$$) {
    my ( $hash, $reading, $value, $unit, $dotrigger ) = @_;
    return undef if ( $value eq ReadingsVal( $hash->{NAME}, $reading, "" ) );
    readingsUnitBeginUpdate($hash);
    my $rv = readingsUnitBulkUpdate( $hash, $reading, $value, $unit );
    readingsUnitEndUpdate( $hash, $dotrigger );
    return $rv;
}

sub readingsUnitBulkUpdateIfChanged($$$@) {
    my ( $hash, $reading, $value, $unit, $changed ) = @_;
    return undef if ( $value eq ReadingsVal( $hash->{NAME}, $reading, "" ) );
    return readingsUnitBulkUpdate( $hash, $reading, $value, $unit, $changed );
}

sub readingsUnitBulkUpdate($$$@) {
    my ( $hash, $reading, $value, $unit, $changed ) = @_;
    my $name = $hash->{NAME};

    return if ( !defined($reading) || !defined($value) );

    # sanity check
    if ( !defined( $hash->{".updateTimestamp"} ) ) {
        Log 1,
          "readingsUnitUpdate($name,$reading,$value,$unit) missed to call "
          . "readingsUnitBeginUpdate first.";
        return;
    }

    my $return = readingsBulkUpdate( $hash, $reading, $value, $changed );
    return $return if !$return;

    $return = setReadingsUnit( $hash, $reading, $unit );
    return $return;
}

# wrapper function for original readingsBeginUpdate
sub readingsUnitBeginUpdate($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    if ( !$name ) {
        Log 1, "ERROR: empty name in readingsUnitBeginUpdate";
        stacktrace();
        return;
    }
    return readingsBeginUpdate($hash);
}

# wrapper function for original readingsEndUpdate
sub readingsUnitEndUpdate($$) {
    my ( $hash, $dotrigger ) = @_;
    my $name = $hash->{NAME};
    return readingsEndUpdate( $hash, $dotrigger );
}

# Generalized function for DbLog unit support
sub Unit_DbLog_split($$) {
    my ( $event, $device ) = @_;
    my ( $reading, $value, $unit ) = "";

    # exclude any multi-value events
    if ( $event =~ /(.*: +.*: +.*)+/ ) {
        Log3 $device, 5,
          "Unit_DbLog_split $device: Ignoring multi-value event $event";
        return undef;
    }

    # exclude sum/cum and avg events
    elsif ( $event =~ /^(.*_sum[0-9]+m|.*_cum[0-9]+m|.*_avg[0-9]+m): +.*/ ) {
        Log3 $device, 5,
          "Unit_DbLog_split $device: Ignoring sum/avg event $event";
        return undef;
    }

    # text conversions
    elsif ( $event =~ /^(pressure_trend_sym): +(\S+) *(.*)/ ) {
        $reading = $1;
        $value   = UConv::sym2pressuretrend($2);
    }
    elsif ( $event =~ /^(UVcondition): +(\S+) *(.*)/ ) {
        $reading = $1;
        $value   = UConv::uvcondition2log($2);
    }
    elsif ( $event =~ /^(Activity): +(\S+) *(.*)/ ) {
        $reading = $1;
        $value   = UConv::activity2log($2);
    }
    elsif ( $event =~ /^(condition): +(\S+) *(.*)/ ) {
        $reading = $1;
        $value   = UConv::weathercondition2log($2);
    }
    elsif ( $event =~ /^(.*[Hh]umidity[Cc]ondition): +(\S+) *(.*)/ ) {
        $reading = $1;
        $value   = UConv::humiditycondition2log($2);
    }

    # general event handling
    elsif ( $event =~ /^(.+): +(\S+) *[\[\{\(]? *([\w\°\%\^\/\\]*).*/ ) {
        $reading = $1;
        $value   = ReadingsNum( $device, $1, $2 );
        $unit    = ReadingsUnit( $device, $1, $3 );
    }

    if ( !Scalar::Util::looks_like_number($value) ) {
        Log3 $device, 5,
"Unit_DbLog_split $device: Ignoring event $event: value does not look like a number";
        return undef;
    }

    Log3 $device, 5,
"Unit_DbLog_split $device: Splitting event $event > reading=$reading value=$value unit=$unit";

    return ( $reading, $value, $unit );
}

################################################################
#
# User commands
#
################################################################

my %unithash = (
    Fn  => "CommandUnit",
    Hlp => "[<devspec>] [<readingspec>],get unit for <devspec> <reading>",
);
$cmds{unit} = \%unithash;

sub CommandUnit($$) {
    my ( $cl, $def ) = @_;
    my $namedef =
"where <devspec> is a single device name, a list separated by comma (,) or a regexp. See the devspec section in the commandref.html for details.\n"
      . "<readingspec> can be a single reading name, a list separated by comma (,) or a regexp.";

    my @a = split( " ", $def, 2 );
    return "Usage: unit [<name>] [<readingspec>]\n$namedef"
      if ( $a[0] && $a[0] eq "?" );
    $a[0] = ".*" if ( !$a[0] || $a[0] eq "" );
    $a[1] = ".*" if ( !$a[1] || $a[1] eq "" );

    my @rets;
    foreach my $sdev ( devspec2array( $a[0], $cl ) ) {
        if ( !defined( $defs{$sdev} ) ) {
            push @rets, "Please define $sdev first";
            next;
        }

        my $readingspec = '^' . $a[1] . '$';
        foreach my $reading (
            grep { /$readingspec/ }
            keys %{ $defs{$sdev}{READINGS} }
          )
        {
            my $ret = ReadingsUnit( $sdev, $reading, undef, undef, 2 );
            push @rets,
              "$sdev $reading unit: $ret ("
              . ReadingsValUnit( $sdev, $reading, "" ) . ")"
              if ($ret);
        }
    }
    return join( "\n", @rets );
}

my %setunithash = (
    Fn  => "CommandSetunit",
    Hlp => "<devspec> <readingspec> [<unit>],set unit for <devspec> <reading>",
);
$cmds{setunit} = \%setunithash;

sub CommandSetunit($$$) {
    my ( $cl, $def ) = @_;
    my $namedef =
"where <devspec> is a single device name, a list separated by comma (,) or a regexp. See the devspec section in the commandref.html for details.\n"
      . "<readingspec> can be a single reading name, a list separated by comma (,) or a regexp.";

    my @a = split( " ", $def, 3 );

    if ( $a[0] && $a[0] eq "?" ) {
        $namedef .= "\n\n";
        my $list = Unit::GetList( "en", $a[1] );
        $namedef .= Dumper($list);
    }

    return "Usage: setunit <name> [<readingspec>] [<unit>]\n$namedef"
      if ( @a < 1 || ( $a[0] && $a[0] eq "?" ) );
    $a[1] = ".*" if ( !$a[1] || $a[1] eq "" );

    my @rets;
    foreach my $sdev ( devspec2array( $a[0], $cl ) ) {
        if ( !defined( $defs{$sdev} ) ) {
            push @rets, "Please define $sdev first";
            next;
        }

        my $readingspec = '^' . $a[1] . '$';
        foreach my $reading (
            grep { /$readingspec/ }
            keys %{ $defs{$sdev}{READINGS} }
          )
        {
            my $ret = setReadingsUnit( $defs{$sdev}, $reading, $a[2] );
            push @rets, $ret if ($ret);
        }
    }
    return join( "\n", @rets );
}

my %deleteunithash = (
    Fn  => "CommandDeleteunit",
    Hlp => "<devspec> [<readingspec>],delete unit for <devspec> <reading>",
);
$cmds{deleteunit} = \%deleteunithash;

sub CommandDeleteunit($$$) {
    my ( $cl, $def ) = @_;
    my $namedef =
"where <devspec> is a single device name, a list separated by comma (,) or a regexp. See the devspec section in the commandref.html for details.\n"
      . "<readingspec> can be a single reading name, a list separated by comma (,) or a regexp.";

    my @a = split( " ", $def, 3 );
    return "Usage: deleteunit <name> [<readingspec>]\n$namedef"
      if ( @a < 1 || ( $a[0] && $a[0] eq "?" ) );
    $a[1] = ".*" if ( !$a[1] || $a[1] eq "" );

    my @rets;
    foreach my $sdev ( devspec2array( $a[0], $cl ) ) {
        if ( !defined( $defs{$sdev} ) ) {
            push @rets, "Please define $sdev first";
            next;
        }

        my $readingspec = '^' . $a[1] . '$';
        foreach my $reading (
            grep { /$readingspec/ }
            keys %{ $defs{$sdev}{READINGS} }
          )
        {
            my $ret = removeReadingsUnit( $defs{$sdev}, $reading );
            push @rets, $ret if ($ret);
        }
    }
    return join( "\n", @rets );
}

####################
# Package: Unit

package Unit;

my %unit_types = (
    0  => "mathematics",
    1  => "temperature",
    2  => "pressure",
    3  => "currency",
    4  => "length",
    5  => "time",
    6  => "speed",
    7  => "weight",
    8  => "solar",
    9  => "volume",
    10 => "energy",
);

my %unitsDB = (

    #TODO really translate all languages

    # math
    "deg" => {
        "unit_type" => 0,
        "unit"      => "°",
        "unit_long" => {
            "de" => "Grad",
            "en" => "degree",
            "fr" => "degree",
            "nl" => "degree",
            "pl" => "degree",
        },
    },

    "pct" => {
        "unit_type" => 0,
        "unit"      => "%",
        "unit_long" => {
            "de" => "Prozent",
            "en" => "percent",
            "fr" => "percent",
            "nl" => "percent",
            "pl" => "percent",
        },
    },

    # temperature
    "c" => {
        "unit_type" => 1,
        "unit"      => "°C",
        "unit_long" => {
            "de" => "Grad Celsius",
            "en" => "Degree Celsius",
            "fr" => "Degree Celsius",
            "nl" => "Degree Celsius",
            "pl" => "Degree Celsius",
        },
    },

    "f" => {
        "unit_type" => 1,
        "unit"      => "°F",
        "unit_long" => {
            "de" => "Grad Fahrenheit",
            "en" => "Degree Fahrenheit",
            "fr" => "Degree Fahrenheit",
            "nl" => "Degree Fahrenheit",
            "pl" => "Degree Fahrenheit",
        },
    },

    "k" => {
        "unit_type" => 1,
        "unit"      => "K",
        "unit_long" => {
            "de" => "Kelvin",
            "en" => "Kelvin",
            "fr" => "Kelvin",
            "nl" => "Kelvin",
            "pl" => "Kelvin",
        },
    },

    # pressure
    "bar" => {
        "unit_type" => 3,
        "unit"      => "bar",
        "unit_long" => {
            "de" => "Bar",
            "en" => "Bar",
            "fr" => "Bar",
            "nl" => "Bar",
            "pl" => "Bar",
        },
    },

    "pa" => {
        "unit_type" => 3,
        "unit"      => "Pa",
        "unit_long" => {
            "de" => "Pascal",
            "en" => "Pascal",
            "fr" => "Pascal",
            "nl" => "Pascal",
            "pl" => "Pascal",
        },
    },

    "hpa" => {
        "unit_type" => 3,
        "unit"      => "hPa",
        "unit_long" => {
            "de" => "Hecto Pascal",
            "en" => "Hecto Pascal",
            "fr" => "Hecto Pascal",
            "nl" => "Hecto Pascal",
            "pl" => "Hecto Pascal",
        },
    },

    "inhg" => {
        "unit_type" => 3,
        "unit"      => "inHg",
        "unit_long" => {
            "de" => "Zoll Quecksilbersäule",
            "en" => "Inches of Mercury",
            "fr" => "Inches of Mercury",
            "nl" => "Inches of Mercury",
            "pl" => "Inches of Mercury",
        },
    },

    "mmhg" => {
        "unit_type" => 3,
        "unit"      => "mmHg",
        "unit_long" => {
            "de" => "Millimeter Quecksilbersäule",
            "en" => "Milimeter of Mercury",
            "fr" => "Milimeter of Mercury",
            "nl" => "Milimeter of Mercury",
            "pl" => "Milimeter of Mercury",
        },
    },

    "torr" => {
        "unit_type" => 3,
        "unit"      => "Torr",
    },

    "psi" => {
        "unit_type" => 3,
        "unit"      => "psi",
        "unit_long" => {
            "de" => "Pfund pro Quadratzoll",
            "en" => "Pound-force per square inch",
            "fr" => "Pound-force per square inch",
            "nl" => "Pound-force per square inch",
            "pl" => "Pound-force per square inch",
        },
    },

    "psia" => {
        "unit_type" => 3,
        "unit"      => "psia",
        "unit_long" => {
            "de" => "Pfund pro Quadratzoll absolut",
            "en" => "pound-force per square inch absolute",
            "fr" => "pound-force per square inch absolute",
            "nl" => "pound-force per square inch absolute",
            "pl" => "pound-force per square inch absolute",
        },
    },

    "psig" => {
        "unit_type" => 3,
        "unit"      => "psig",
        "unit_long" => {
            "de" => "Pfund pro Quadratzoll relativ",
            "en" => "pounds-force per square inch gauge",
            "fr" => "pounds-force per square inch gauge",
            "nl" => "pounds-force per square inch gauge",
            "pl" => "pounds-force per square inch gauge",
        },
    },

    # length
    "km" => {
        "unit_type" => 4,
        "unit"      => "km",
        "unit_long" => {
            "de" => "Kilometer",
            "en" => "kilometer",
            "fr" => "kilometer",
            "nl" => "kilometer",
            "pl" => "kilometer",
        },
    },

    "m" => {
        "unit_type" => 4,
        "unit"      => "m",
        "unit_long" => {
            "de" => "Meter",
            "en" => "meter",
            "fr" => "meter",
            "nl" => "meter",
            "pl" => "meter",
        },
    },

    "mm" => {
        "unit_type" => 4,
        "unit"      => "mm",
        "unit_long" => {
            "de" => "Millimeter",
            "en" => "milimeter",
            "fr" => "milimeter",
            "nl" => "milimeter",
            "pl" => "milimeter",
        },
    },

    "cm" => {
        "unit_type" => 4,
        "unit"      => "cm",
        "unit_long" => {
            "de" => "Zentimeter",
            "en" => "centimeter",
            "fr" => "centimeter",
            "nl" => "centimeter",
            "pl" => "centimeter",
        },
    },

    "in" => {
        "unit_type"   => 4,
        "unit_symbol" => "″",
        "unit"        => "in",
        "unit_long"   => {
            "de" => "Zoll",
            "en" => "inch",
            "fr" => "inch",
            "nl" => "inch",
            "pl" => "inch",
        },
        "unit_long_pl" => {
            "de" => "Zoll",
            "en" => "inches",
            "fr" => "inches",
            "nl" => "inches",
            "pl" => "inches",
        },
        "txt_format"         => '%value%%unit_symbol%',
        "txt_format_long"    => '%value% %unit_long%',
        "txt_format_long_pl" => '%value% %unit_long_pl%',
    },

    "ft" => {
        "unit_type"   => 4,
        "unit_symbol" => "′",
        "unit"        => "ft",
        "unit_long"   => {
            "de" => "Fuss",
            "en" => "foot",
            "fr" => "foot",
            "nl" => "foot",
            "pl" => "foot",
        },
        "unit_long_pl" => {
            "de" => "Fuss",
            "en" => "feet",
            "fr" => "feet",
            "nl" => "feet",
            "pl" => "feet",
        },
        "txt_format"         => '%value%%unit_symbol%',
        "txt_format_long"    => '%value% %unit_long%',
        "txt_format_long_pl" => '%value% %unit_long_pl%',
    },

    "yd" => {
        "unit_type" => 4,
        "unit"      => "yd",
        "unit_long" => {
            "de" => "Yard",
            "en" => "yard",
            "fr" => "yard",
            "nl" => "yard",
            "pl" => "yard",
        },
        "unit_long_pl" => {
            "de" => "Yards",
            "en" => "yards",
            "fr" => "yards",
            "nl" => "yards",
            "pl" => "yards",
        },
    },

    "mi" => {
        "unit_type" => 4,
        "unit"      => "mi",
        "unit_long" => {
            "de" => "Meilen",
            "en" => "miles",
            "fr" => "miles",
            "nl" => "miles",
            "pl" => "miles",
        },
    },

    # time
    "sec" => {
        "unit_type" => 5,
        "unit"      => {
            "de" => "s",
            "en" => "s",
            "fr" => "s",
            "nl" => "s",
            "pl" => "s",
        },
        "unit_long" => {
            "de" => "Sekunde",
            "en" => "second",
            "fr" => "second",
            "nl" => "second",
            "pl" => "second",
        },
        "unit_long_pl" => {
            "de" => "Sekunden",
            "en" => "seconds",
            "fr" => "seconds",
            "nl" => "seconds",
            "pl" => "seconds",
        },
    },

    "min" => {
        "unit_type" => 5,
        "unit"      => {
            "de" => "Min",
            "en" => "min",
            "fr" => "min",
            "nl" => "min",
            "pl" => "min",
        },
        "unit_long" => {
            "de" => "Minute",
            "en" => "minute",
            "fr" => "minute",
            "nl" => "minute",
            "pl" => "minute",
        },
        "unit_long_pl" => {
            "de" => "Minuten",
            "en" => "minutes",
            "fr" => "minutes",
            "nl" => "minutes",
            "pl" => "minutes",
        },
    },

    "hr" => {
        "unit_type" => 5,
        "unit"      => {
            "de" => "Std",
            "en" => "hr",
            "fr" => "hr",
            "nl" => "hr",
            "pl" => "hr",
        },
        "unit_long" => {
            "de" => "Stunde",
            "en" => "hour",
            "fr" => "hour",
            "nl" => "hour",
            "pl" => "hour",
        },
        "unit_long_pl" => {
            "de" => "Stunden",
            "en" => "hours",
            "fr" => "hours",
            "nl" => "hours",
            "pl" => "hours",
        },
    },

    "d" => {
        "unit_type" => 5,
        "unit"      => {
            "de" => "T",
            "en" => "d",
            "fr" => "d",
            "nl" => "d",
            "pl" => "d",
        },
        "unit_long" => {
            "de" => "Tag",
            "en" => "day",
            "fr" => "day",
            "nl" => "day",
            "pl" => "day",
        },
        "unit_long_pl" => {
            "de" => "Tage",
            "en" => "days",
            "fr" => "days",
            "nl" => "days",
            "pl" => "days",
        },
    },

    "w" => {
        "unit_type" => 5,
        "unit"      => {
            "de" => "W",
            "en" => "w",
            "fr" => "w",
            "nl" => "w",
            "pl" => "w",
        },
        "unit_long" => {
            "de" => "Woche",
            "en" => "week",
            "fr" => "week",
            "nl" => "week",
            "pl" => "week",
        },
        "unit_long_pl" => {
            "de" => "Wochen",
            "en" => "weeks",
            "fr" => "weeks",
            "nl" => "weeks",
            "pl" => "weeks",
        },
    },

    "m" => {
        "unit_type" => 5,
        "unit"      => {
            "de" => "M",
            "en" => "m",
            "fr" => "m",
            "nl" => "m",
            "pl" => "m",
        },
        "unit_long" => {
            "de" => "Monat",
            "en" => "month",
            "fr" => "month",
            "nl" => "month",
            "pl" => "month",
        },
        "unit_long_pl" => {
            "de" => "Monate",
            "en" => "Monat",
            "fr" => "Monat",
            "nl" => "Monat",
            "pl" => "Monat",
        },
    },

    "y" => {
        "unit_type" => 5,
        "unit"      => {
            "de" => "J",
            "en" => "y",
            "fr" => "y",
            "nl" => "y",
            "pl" => "y",
        },
        "unit_long" => {
            "de" => "Jahr",
            "en" => "year",
            "fr" => "year",
            "nl" => "year",
            "pl" => "year",
        },
        "unit_long_pl" => {
            "de" => "Jahre",
            "en" => "years",
            "fr" => "years",
            "nl" => "years",
            "pl" => "years",
        },
    },

    # speed
    "bft" => {
        "unit_type" => 6,
        "unit"      => "bft",
        "unit_long" => {
            "de" => "Windstärke",
            "en" => "wind force",
            "fr" => "wind force",
            "nl" => "wind force",
            "pl" => "wind force",
        },
        "txt_format_long" => '%unit_long% %value%',
    },

    "fts" => {
        "unit_type" => 6,
        "unit"      => "ft/s",
        "unit_long" => {
            "de" => "Feet pro Sekunde",
            "en" => "feets per second",
            "fr" => "feets per second",
            "nl" => "feets per second",
            "pl" => "feets per second",
        },
    },

    "kmh" => {
        "unit_type" => 6,
        "unit"      => "km/h",
        "unit_long" => {
            "de" => "Kilometer pro Stunde",
            "en" => "kilometer per hour",
            "fr" => "kilometer per hour",
            "nl" => "kilometer per hour",
            "pl" => "kilometer per hour",
        },
    },

    "kn" => {
        "unit_type" => 6,
        "unit"      => "kn",
        "unit_long" => {
            "de" => "Knoten",
            "en" => "knots",
            "fr" => "knots",
            "nl" => "knots",
            "pl" => "knots",
        },
    },

    "mph" => {
        "unit_type" => 6,
        "unit"      => "mi/h",
        "unit_long" => {
            "de" => "Meilen pro Stunde",
            "en" => "miles per hour",
            "fr" => "miles per hour",
            "nl" => "miles per hour",
            "pl" => "miles per hour",
        },
    },

    "mps" => {
        "unit_type" => 6,
        "unit"      => "m/s",
        "unit_long" => {
            "de" => "Meter pro Sekunde",
            "en" => "meter per second",
            "fr" => "meter per second",
            "nl" => "meter per second",
            "pl" => "meter per second",
        },
    },

    # weight
    "mol" => {
        "unit_type" => 7,
        "unit"      => "mol",
    },

    "n" => {
        "unit_type" => 7,
        "unit"      => "N",
        "unit_long" => {
            "de" => "Newton",
            "en" => "Newton",
            "fr" => "Newton",
            "nl" => "Newton",
            "pl" => "Newton",
        },
    },

    "g" => {
        "unit_type" => 7,
        "unit"      => "g",
        "unit_long" => {
            "de" => "Gramm",
            "en" => "gram",
            "fr" => "gram",
            "nl" => "gram",
            "pl" => "gram",
        },
    },

    "dg" => {
        "unit_type" => 7,
        "unit"      => "dg",
        "unit_long" => {
            "de" => "Dekagramm",
            "en" => "dekagram",
            "fr" => "dekagram",
            "nl" => "dekagram",
            "pl" => "dekagram",
        },
    },

    "kg" => {
        "unit_type" => 7,
        "unit"      => "kg",
        "unit_long" => {
            "de" => "Kilogramm",
            "en" => "kilogram",
            "fr" => "kilogram",
            "nl" => "kilogram",
            "pl" => "kilogram",
        },
    },

    "t" => {
        "unit_type" => 7,
        "unit"      => "t",
        "unit_long" => {
            "de" => "Tonne",
            "en" => "ton",
            "fr" => "ton",
            "nl" => "ton",
            "pl" => "ton",
        },
        "unit_long_pl" => {
            "de" => "Tonnen",
            "en" => "tons",
            "fr" => "tons",
            "nl" => "tons",
            "pl" => "tons",
        },
    },

    "lb" => {
        "unit_type" => 7,
        "unit"      => "lb",
        "unit_long" => {
            "de" => "Pfund",
            "en" => "pound",
            "fr" => "pound",
            "nl" => "pound",
            "pl" => "pound",
        },
    },

    "lbs" => {
        "unit_type" => 7,
        "unit"      => "lbs",
        "unit_long" => {
            "de" => "Pfund",
            "en" => "pound",
            "fr" => "pound",
            "nl" => "pound",
            "pl" => "pound",
        },
    },

    # solar
    "cd" => {
        "unit_type" => 8,
        "unit"      => "cd",
        "unit_long" => {
            "de" => "Candela",
            "en" => "Candela",
            "fr" => "Candela",
            "nl" => "Candela",
            "pl" => "Candela",
        },
    },

    "lx" => {
        "unit_type" => 8,
        "unit"      => "lx",
        "unit_long" => {
            "de" => "Lux",
            "en" => "Lux",
            "fr" => "Lux",
            "nl" => "Lux",
            "pl" => "Lux",
        },
    },

    "lm" => {
        "unit_type" => 8,
        "unit"      => "lm",
        "unit_long" => {
            "de" => "Lumen",
            "en" => "Lumen",
            "fr" => "Lumen",
            "nl" => "Lumen",
            "pl" => "Lumen",
        },
    },

    "uvi" => {
        "unit_type" => 8,
        "unit"      => "UVI",
        "unit_long" => {
            "de" => "UV-Index",
            "en" => "UV-Index",
            "fr" => "UV-Index",
            "nl" => "UV-Index",
            "pl" => "UV-Index",
        },
        "txt_format"         => '%unit% %value%',
        "txt_format_long"    => '%unit_long% %value%',
        "txt_format_long_pl" => '%unit_long% %value%',
    },

    # volume
    "ml" => {
        "unit_type" => 9,
        "unit"      => "ml",
        "unit_long" => {
            "de" => "Milliliter",
            "en" => "mililitre",
            "fr" => "mililitre",
            "nl" => "mililitre",
            "pl" => "mililitre",
        },
        "unit_long_pl" => {
            "de" => "Milliliter",
            "en" => "mililitres",
            "fr" => "mililitres",
            "nl" => "mililitres",
            "pl" => "mililitres",
        },
    },

    "l" => {
        "unit_type" => 9,
        "unit"      => "l",
        "unit_long" => {
            "de" => "Liter",
            "en" => "litre",
            "fr" => "litre",
            "nl" => "litre",
            "pl" => "litre",
        },
        "unit_long_pl" => {
            "de" => "Liter",
            "en" => "litres",
            "fr" => "litres",
            "nl" => "litres",
            "pl" => "litres",
        },
    },

    "oz" => {
        "unit_type" => 9,
        "unit"      => "oz",
        "unit_long" => {
            "de" => "Unze",
            "en" => "ounce",
            "fr" => "ounce",
            "nl" => "ounce",
            "pl" => "ounce",
        },
        "unit_long_pl" => {
            "de" => "Unzen",
            "en" => "ounces",
            "fr" => "ounces",
            "nl" => "ounces",
            "pl" => "ounces",
        },
    },

    "floz" => {
        "unit_type" => 9,
        "unit"      => "fl oz",
        "unit_long" => {
            "de" => "fl. Unze",
            "en" => "fl. ounce",
            "fr" => "fl. ounce",
            "nl" => "fl. ounce",
            "pl" => "fl. ounce",
        },
        "unit_long_pl" => {
            "de" => "fl. Unzen",
            "en" => "fl. ounces",
            "fr" => "fl. ounces",
            "nl" => "fl. ounces",
            "pl" => "fl. ounces",
        },
    },

    "ozfl" => {
        "unit_type" => 9,
        "unit"      => "fl oz",
        "unit_long" => {
            "de" => "fl. Unze",
            "en" => "fl. ounce",
            "fr" => "fl. ounce",
            "nl" => "fl. ounce",
            "pl" => "fl. ounce",
        },
        "unit_long_pl" => {
            "de" => "fl. Unzen",
            "en" => "fl. ounces",
            "fr" => "fl. ounces",
            "nl" => "fl. ounces",
            "pl" => "fl. ounces",
        },
    },

    "quart" => {
        "unit_type" => 9,
        "unit"      => "quart",
        "unit_long" => {
            "de" => "Quart",
            "en" => "quart",
            "fr" => "quart",
            "nl" => "quart",
            "pl" => "quart",
        },
        "unit_long_pl" => {
            "de" => "Quarts",
            "en" => "quarts",
            "fr" => "quarts",
            "nl" => "quarts",
            "pl" => "quarts",
        },
    },

    "gallon" => {
        "unit_type" => 9,
        "unit"      => "gallon",
        "unit_long" => {
            "de" => "Gallone",
            "en" => "gallon",
            "fr" => "gallon",
            "nl" => "gallon",
            "pl" => "gallon",
        },
        "unit_long_pl" => {
            "de" => "Gallonen",
            "en" => "gallons",
            "fr" => "gallons",
            "nl" => "gallons",
            "pl" => "gallons",
        },
    },

    # energy
    "b" => {
        "unit_type" => 10,
        "unit"      => "B",
        "unit_long" => {
            "de" => "Bel",
            "en" => "Bel",
            "fr" => "Bel",
            "nl" => "Bel",
            "pl" => "Bel",
        },
    },

    "db" => {
        "unit_type" => 10,
        "unit"      => "dB",
        "unit_long" => {
            "de" => "Dezibel",
            "en" => "Decibel",
            "fr" => "Decibel",
            "nl" => "Decibel",
            "pl" => "Decibel",
        },
    },

    "uwpscm" => {
        "unit_type" => 10,
        "unit"      => "uW/cm2",
        "unit_long" => {
            "de" => "Micro-Watt pro Quadratzentimeter",
            "en" => "Micro-Watt per square centimeter",
            "fr" => "Micro-Watt per square centimeter",
            "nl" => "Micro-Watt per square centimeter",
            "pl" => "Micro-Watt per square centimeter",
        },
    },

    "wpsm" => {
        "unit_type" => 10,
        "unit"      => "W/m2",
        "unit_long" => {
            "de" => "Watt pro Quadratmeter",
            "en" => "Watt per square meter",
            "fr" => "Watt per square meter",
            "nl" => "Watt per square meter",
            "pl" => "Watt per square meter",
        },
    },

    "a" => {
        "unit_type" => 10,
        "unit"      => "A",
        "unit_long" => {
            "de" => "Ampere",
            "en" => "Ampere",
            "fr" => "Ampere",
            "nl" => "Ampere",
            "pl" => "Ampere",
        },
    },

    "v" => {
        "unit_type" => 10,
        "unit"      => "V",
        "unit_long" => {
            "de" => "Volt",
            "en" => "Volt",
            "fr" => "Volt",
            "nl" => "Volt",
            "pl" => "Volt",
        },
    },

    "w" => {
        "unit_type" => 10,
        "unit"      => "Watt",
        "unit_long" => {
            "de" => "Watt",
            "en" => "Watt",
            "fr" => "Watt",
            "nl" => "Watt",
            "pl" => "Watt",
        },
    },

    "j" => {
        "unit_type" => 10,
        "unit"      => "J",
        "unit_long" => {
            "de" => "Joule",
            "en" => "Joule",
            "fr" => "Joule",
            "nl" => "Joule",
            "pl" => "Joule",
        },
    },

    "coul" => {
        "unit_type" => 10,
        "unit"      => "C",
        "unit_long" => {
            "de" => "Coulomb",
            "en" => "Coulomb",
            "fr" => "Coulomb",
            "nl" => "Coulomb",
            "pl" => "Coulomb",
        },
    },

    "far" => {
        "unit_type" => 10,
        "unit"      => "F",
        "unit_long" => {
            "de" => "Farad",
            "en" => "Farad",
            "fr" => "Farad",
            "nl" => "Farad",
            "pl" => "Farad",
        },
    },

    "ohm" => {
        "unit_type" => 10,
        "unit"      => "Ω",
        "unit_long" => {
            "de" => "Ohm",
            "en" => "Ohm",
            "fr" => "Ohm",
            "nl" => "Ohm",
            "pl" => "Ohm",
        },
    },

    "s" => {
        "unit_type" => 10,
        "unit"      => "S",
        "unit_long" => {
            "de" => "Siemens",
            "en" => "Siemens",
            "fr" => "Siemens",
            "nl" => "Siemens",
            "pl" => "Siemens",
        },
    },

    "wb" => {
        "unit_type" => 10,
        "unit"      => "Wb",
        "unit_long" => {
            "de" => "Weber",
            "en" => "Weber",
            "fr" => "Weber",
            "nl" => "Weber",
            "pl" => "Weber",
        },
    },

    "t" => {
        "unit_type" => 10,
        "unit"      => "T",
        "unit_long" => {
            "de" => "Tesla",
            "en" => "Tesla",
            "fr" => "Tesla",
            "nl" => "Tesla",
            "pl" => "Tesla",
        },
    },

    "h" => {
        "unit_type" => 10,
        "unit"      => "H",
        "unit_long" => {
            "de" => "Henry",
            "en" => "Henry",
            "fr" => "Henry",
            "nl" => "Henry",
            "pl" => "Henry",
        },
    },

    "bq" => {
        "unit_type" => 10,
        "unit"      => "Bq",
        "unit_long" => {
            "de" => "Becquerel",
            "en" => "Becquerel",
            "fr" => "Becquerel",
            "nl" => "Becquerel",
            "pl" => "Becquerel",
        },
    },

    "gy" => {
        "unit_type" => 10,
        "unit"      => "Gy",
        "unit_long" => {
            "de" => "Gray",
            "en" => "Gray",
            "fr" => "Gray",
            "nl" => "Gray",
            "pl" => "Gray",
        },
    },

    "sv" => {
        "unit_type" => 10,
        "unit"      => "Sv",
        "unit_long" => {
            "de" => "Sievert",
            "en" => "Sievert",
            "fr" => "Sievert",
            "nl" => "Sievert",
            "pl" => "Sievert",
        },
    },

    "kat" => {
        "unit_type" => 10,
        "unit"      => "kat",
        "unit_long" => {
            "de" => "Katal",
            "en" => "Katal",
            "fr" => "Katal",
            "nl" => "Katal",
            "pl" => "Katal",
        },
    },

);

my %readingsDB = (
    "airpress" => {
        "unified" => "pressure_hpa",    # link only
    },
    "azimuth" => {
        "short" => "AZ",
        "unit"  => "deg",
    },
    "compasspoint" => {
        "short" => "CP",
    },
    "dewpoint" => {
        "unified" => "dewpoint_c",      # link only
    },
    "dewpoint_c" => {
        "short" => "D",
        "unit"  => "c",
    },
    "dewpoint_f" => {
        "short" => "Df",
        "unit"  => "f",
    },
    "dewpoint_k" => {
        "short" => "Dk",
        "unit"  => "k",
    },
    "elevation" => {
        "short" => "EL",
        "unit"  => "deg",
    },
    "feelslike" => {
        "unified" => "feelslike_c",    # link only
    },
    "feelslike_c" => {
        "short" => "Tf",
        "unit"  => "c",
    },
    "feelslike_f" => {
        "short" => "Tff",
        "unit"  => "f",
    },
    "heat_index" => {
        "unified" => "heat_index_c",    # link only
    },
    "heat_index_c" => {
        "short" => "HI",
        "unit"  => "c",
    },
    "heat_index_f" => {
        "short" => "HIf",
        "unit"  => "f",
    },
    "high" => {
        "unified" => "high_c",          # link only
    },
    "high_c" => {
        "short" => "Th",
        "unit"  => "c",
    },
    "high_f" => {
        "short" => "Thf",
        "unit"  => "f",
    },
    "humidity" => {
        "short" => "H",
        "unit"  => "pct",
    },
    "humidityabs" => {
        "unified" => "humidityabs_c",    # link only
    },
    "humidityabs_c" => {
        "short" => "Ha",
        "unit"  => "c",
    },
    "humidityabs_f" => {
        "short" => "Haf",
        "unit"  => "f",
    },
    "humidityabs_k" => {
        "short" => "Hak",
        "unit"  => "k",
    },
    "horizon" => {
        "short" => "HORIZ",
        "unit"  => "deg",
    },
    "indoordewpoint" => {
        "unified" => "indoordewpoint_c",    # link only
    },
    "indoordewpoint_c" => {
        "short" => "Di",
        "unit"  => "c",
    },
    "indoordewpoint_f" => {
        "short" => "Dif",
        "unit"  => "f",
    },
    "indoordewpoint_k" => {
        "short" => "Dik",
        "unit"  => "k",
    },
    "indoorhumidity" => {
        "short" => "Hi",
        "unit"  => "pct",
    },
    "indoorhumidityabs" => {
        "unified" => "indoorhumidityabs_c",    # link only
    },
    "indoorhumidityabs_c" => {
        "short" => "Hai",
        "unit"  => "c",
    },
    "indoorhumidityabs_f" => {
        "short" => "Haif",
        "unit"  => "f",
    },
    "indoorhumidityabs_k" => {
        "short" => "Haik",
        "unit"  => "k",
    },
    "indoortemperature" => {
        "unified" => "indoortemperature_c",    # link only
    },
    "indoortemperature_c" => {
        "short" => "Ti",
        "unit"  => "c",
    },
    "indoortemperature_f" => {
        "short" => "Tif",
        "unit"  => "f",
    },
    "indoortemperature_k" => {
        "short" => "Tik",
        "unit"  => "k",
    },
    "israining" => {
        "short" => "IR",
    },
    "level" => {
        "short" => "LVL",
        "unit"  => "pct",
    },
    "low" => {
        "unified" => "low_c",    # link only
    },
    "low_c" => {
        "short" => "Tl",
        "unit"  => "c",
    },
    "low_f" => {
        "short" => "Tlf",
        "unit"  => "f",
    },
    "luminosity" => {
        "short" => "L",
        "unit"  => "lx",
    },
    "pct" => {
        "short" => "PCT",
        "unit"  => "pct",
    },
    "pressure" => {
        "unified" => "pressure_hpa",    # link only
    },
    "pressure_hpa" => {
        "short" => "P",
        "unit"  => "hpa",
    },
    "pressure_in" => {
        "short" => "Pin",
        "unit"  => "inhg",
    },
    "pressure_mm" => {
        "short" => "Pmm",
        "unit"  => "mmhg",
    },
    "pressure_psi" => {
        "short" => "Ppsi",
        "unit"  => "psi",
    },
    "pressure_psig" => {
        "short" => "Ppsi",
        "unit"  => "psig",
    },
    "pressureabs" => {
        "unified" => "pressureabs_hpa",    # link only
    },
    "pressureabs_hpa" => {
        "short" => "Pa",
        "unit"  => "hpa",
    },
    "pressureabs_in" => {
        "short" => "Pain",
        "unit"  => "inhg",
    },
    "pressureabs_mm" => {
        "short" => "Pamm",
        "unit"  => "mmhg",
    },
    "pressureabs_psi" => {
        "short" => "Ppsia",
        "unit"  => "psia",
    },
    "pressureabs_psia" => {
        "short" => "Ppsia",
        "unit"  => "psia",
    },
    "rain" => {
        "unified" => "rain_mm",    # link only
    },
    "rain_mm" => {
        "short" => "R",
        "unit"  => "mm",
    },
    "rain_in" => {
        "short" => "Rin",
        "unit"  => "in",
    },
    "rain_day" => {
        "unified" => "rain_day_mm",    # link only
    },
    "rain_day_mm" => {
        "short" => "Rd",
        "unit"  => "mm",
    },
    "rain_day_in" => {
        "short" => "Rdin",
        "unit"  => "in",
    },
    "rain_night" => {
        "unified" => "rain_night_mm",    # link only
    },
    "rain_night_mm" => {
        "short" => "Rn",
        "unit"  => "mm",
    },
    "rain_night_in" => {
        "short" => "Rnin",
        "unit"  => "in",
    },
    "rain_week" => {
        "unified" => "rain_week_mm",     # link only
    },
    "rain_week_mm" => {
        "short" => "Rw",
        "unit"  => "mm",
    },
    "rain_week_in" => {
        "short" => "Rwin",
        "unit"  => "in",
    },
    "rain_month" => {
        "unified" => "rain_month_mm",    # link only
    },
    "rain_month_mm" => {
        "short" => "Rm",
        "unit"  => "mm",
    },
    "rain_month_in" => {
        "short" => "Rmin",
        "unit"  => "in",
    },
    "rain_year" => {
        "unified" => "rain_year_mm",     # link only
    },
    "rain_year_mm" => {
        "short" => "Ry",
        "unit"  => "mm",
    },
    "rain_year_in" => {
        "short" => "Ryin",
        "unit"  => "in",
    },
    "snow" => {
        "unified" => "snow_cm",          # link only
    },
    "snow_cm" => {
        "short" => "S",
        "unit"  => "cm",
    },
    "snow_in" => {
        "short" => "Sin",
        "unit"  => "in",
    },
    "snow_day" => {
        "unified" => "snow_day_cm",      # link only
    },
    "snow_day_cm" => {
        "short" => "Sd",
        "unit"  => "cm",
    },
    "snow_day_in" => {
        "short" => "Sdin",
        "unit"  => "in",
    },
    "snow_night" => {
        "unified" => "snow_night_cm",    # link only
    },
    "snow_night_cm" => {
        "short" => "Sn",
        "unit"  => "cm",
    },
    "snow_night_in" => {
        "short" => "Snin",
        "unit"  => "in",
    },
    "sunshine" => {
        "unified" => "solarradiation",    # link only
    },
    "solarradiation" => {
        "short" => "SR",
        "unit"  => "wpsm",
    },
    "temp" => {
        "unified" => "temperature_c",     # link only
    },
    "temp_c" => {
        "unified" => "temperature_c",     # link only
    },
    "temp_f" => {
        "unified" => "temperature_f",     # link only
    },
    "temp_k" => {
        "unified" => "temperature_k",     # link only
    },
    "temperature" => {
        "unified" => "temperature_c",     # link only
    },
    "temperature_c" => {
        "short" => "T",
        "unit"  => "c",
    },
    "temperature_f" => {
        "short" => "Tf",
        "unit"  => "f",
    },
    "temperature_k" => {
        "short" => "Tk",
        "unit"  => "k",
    },
    "uv" => {
        "unified" => "uvi",    # link only
    },
    "uvi" => {
        "short" => "UV",
        "unit"  => "uvi",
    },
    "uvr" => {
        "short" => "UVR",
        "unit"  => "uwpscm",
    },
    "valvedesired" => {
        "unified" => "valve",    # link only
    },
    "valvepos" => {
        "unified" => "valve",    # link only
    },
    "valveposition" => {
        "unified" => "valve",    # link only
    },
    "valvepostc" => {
        "unified" => "valve",    # link only
    },
    "valve" => {
        "short" => "VAL",
        "unit"  => "pct",
    },
    "visibility" => {
        "unified" => "visibility_km",    # link only
    },
    "visibility_km" => {
        "short" => "V",
        "unit"  => "km",
    },
    "visibility_mi" => {
        "short" => "Vmi",
        "unit"  => "mi",
    },
    "wind_chill" => {
        "unified" => "wind_chill_c",     # link only
    },
    "wind_chill_c" => {
        "short" => "Wc",
        "unit"  => "c",
    },
    "wind_chill_f" => {
        "short" => "Wcf",
        "unit"  => "f",
    },
    "wind_chill_k" => {
        "short" => "Wck",
        "unit"  => "k",
    },
    "wind_compasspoint" => {
        "short" => "Wdc",
    },
    "windspeeddirection" => {
        "unified" => "wind_compasspoint",    # link only
    },
    "winddirectiontext" => {
        "unified" => "wind_compasspoint",    # link only
    },
    "wind_direction" => {
        "short" => "Wd",
        "unit"  => "deg",
    },
    "wind_dir" => {
        "unified" => "wind_direction",       # link only
    },
    "winddir" => {
        "unified" => "wind_direction",       # link only
    },
    "winddirection" => {
        "unified" => "wind_direction",       # link only
    },
    "wind_gust" => {
        "unified" => "wind_gust_kmh",        # link only
    },
    "wind_gust_kmh" => {
        "short" => "Wg",
        "unit"  => "kmh",
    },
    "wind_gust_bft" => {
        "short" => "Wgbft",
        "unit"  => "bft",
    },
    "wind_gust_fts" => {
        "short" => "Wgfts",
        "unit"  => "fts",
    },
    "wind_gust_kn" => {
        "short" => "Wgkn",
        "unit"  => "kn",
    },
    "wind_gust_mph" => {
        "short" => "Wgmph",
        "unit"  => "mph",
    },
    "wind_gust_mps" => {
        "short" => "Wgmps",
        "unit"  => "mps",
    },
    "wind_speed" => {
        "unified" => "wind_speed_kmh",    # link only
    },
    "wind_speed_kmh" => {
        "short" => "Ws",
        "unit"  => "kmh",
    },
    "wind_speed_bft" => {
        "short" => "Wsbft",
        "unit"  => "bft",
    },
    "wind_speed_fts" => {
        "short" => "Wsfts",
        "unit"  => "fts",
    },
    "wind_speed_kn" => {
        "short" => "Wskn",
        "unit"  => "kn",
    },
    "wind_speed_mph" => {
        "short" => "Wsmph",
        "unit"  => "mph",
    },
    "wind_speed_mps" => {
        "short" => "Wsmps",
        "unit"  => "mps",
    },
);

# Get unit list in local language as hash
sub GetList (@) {
    my ( $lang, $type ) = @_;
    my %list;

    foreach my $u ( keys %unitsDB ) {
        my $details = GetDetails( $u, $lang );
        my $tid     = $details->{"unit_type"};
        my $tn      = ( $unit_types{$tid} ? $unit_types{$tid} : "unknown" );
        $list{$tn}{$u} = $details
          if ( !$type || $type eq $tid || lc($type) eq $tn );
    }

    return \%list;
}

# Get unit details in local language as hash
sub GetDetails ($@) {
    my ( $unit, $lang ) = @_;
    my $u = lc($unit);
    my $l = ( $lang ? lc($lang) : "en" );
    my %details;

    return {} if ( !$unit || $unit eq "" );

    if ( defined( $unitsDB{$u} ) ) {
        foreach my $k ( keys %{ $unitsDB{$u} } ) {
            $details{$k} = $unitsDB{$u}{$k};
        }
        $details{"unit_abbr"} = $u;

        if ($lang) {
            $details{"lang"} = $l;

            if (   $details{"txt_format"}
                && ref( $unitsDB{$u}{"txt_format"} ) eq "HASH"
                && $unitsDB{$u}{"txt_format"}{$l} )
            {
                delete $details{"txt_format"};
                $details{"txt_format"} = $unitsDB{$u}{"txt_format"}{$l};
            }

            if (   $details{"txt_format_long"}
                && ref( $unitsDB{$u}{"txt_format_long"} ) eq "HASH"
                && $unitsDB{$u}{"txt_format_long"}{$l} )
            {
                delete $details{"txt_format_long"};
                $details{"txt_format_long"} =
                  $unitsDB{$u}{"txt_format_long"}{$l};
            }

            if (   $details{"txt_format_long_pl"}
                && ref( $unitsDB{$u}{"txt_format_long_pl"} ) eq "HASH"
                && $unitsDB{$u}{"txt_format_long_pl"}{$l} )
            {
                delete $details{"txt_format_long_pl"};
                $details{"txt_format_long_pl"} =
                  $unitsDB{$u}{"txt_format_long_pl"}{$l};
            }

            if (   $details{"unit"}
                && ref( $unitsDB{$u}{"unit"} ) eq "HASH"
                && $unitsDB{$u}{"unit"}{$l} )
            {
                delete $details{"unit"};
                $details{"unit"} = $unitsDB{$u}{"unit"}{$l};
            }

            if (   $details{"unit_long"}
                && ref( $unitsDB{$u}{"unit_long"} ) eq "HASH"
                && $unitsDB{$u}{"unit_long"}{$l} )
            {
                delete $details{"unit_long"};
                $details{"unit_long"} = $unitsDB{$u}{"unit_long"}{$l};
            }

            if (   $details{"unit_long_pl"}
                && ref( $unitsDB{$u}{"unit_long_pl"} ) eq "HASH"
                && $unitsDB{$u}{"unit_long_pl"}{$l} )
            {
                delete $details{"unit_long_pl"};
                $details{"unit_long_pl"} = $unitsDB{$u}{"unit_long_pl"}{$l};
            }

        }

        return \%details;
    }
}

# Get unit details in local language from reading name as hash
sub GetDetailsFromReadingname ($@) {
    my ( $reading, $lang ) = @_;
    my $details;
    my $r = $reading;
    my $l = ( $lang ? lc($lang) : "en" );
    my $u;
    my %return;

    # remove some prefix or other values to
    # flatten reading name
    $r =~ s/^fc\d+_//i;
    $r =~ s/_(min|max|avg|sum|cum|avg\d+m|sum\d+m|cum\d+m)_/_/i;
    $r =~ s/^(min|max|avg|sum|cum|avg\d+m|sum\d+m|cum\d+m)_//i;
    $r =~ s/_(min|max|avg|sum|cum|avg\d+m|sum\d+m|cum\d+m)$//i;
    $r =~ s/.*[-_](temp)$/$1/i;

    # rename capital letter containing readings
    if ( !$readingsDB{ lc($r) } ) {
        $r =~ s/^([A-Z])(.*)/\l$1$2/;
        $r =~ s/([A-Z][a-z0-9]+)[\/\|\-_]?/_$1/g;
    }

    $r = lc($r);

    # known alias reading names
    if ( $readingsDB{$r}{"unified"} ) {
        my $dr = $readingsDB{$r}{"unified"};
        $return{"unified"} = $dr;
        $return{"short"}   = $readingsDB{$dr}{"short"};
        $u                 = (
              $readingsDB{$dr}{"unit"}
            ? $readingsDB{$dr}{"unit"}
            : "-"
        );
    }

    # known standard reading names
    elsif ( $readingsDB{$r}{"short"} ) {
        $return{"unified"} = $reading;
        $return{"short"}   = $readingsDB{$r}{"short"};
        $u                 = (
              $readingsDB{$r}{"unit"}
            ? $readingsDB{$r}{"unit"}
            : "-"
        );
    }

    # just guessing the unit from reading name format
    elsif ( $r =~ /_([a-z]+)$/ ) {
        $u = lc($1);
    }

    return if ( !%return && !$u );
    return \%return if ( !$u );

    my $unitDetails = GetDetails( $u, $l );

    if ( ref($unitDetails) eq "HASH" ) {
        $return{"unified"}    = $reading if ( !$return{"unified"} );
        $return{"unit_guess"} = "1"      if ( !$return{"short"} );
        foreach my $k ( keys %{$unitDetails} ) {
            $return{$k} = $unitDetails->{$k};
        }
    }

    return \%return;
}

# Get value + unit combined string
sub GetValueWithUnit ($$@) {
    my ( $value, $unit, $lang, $format ) = @_;
    my $l = ( $lang ? lc($lang) : "en" );
    my $return = GetDetails( $unit, $l );
    my $txt;
    return $value if ( !$return->{"unit"} );

    $return->{"value"} = $value;

    # long plural
    if (   $format
        && Scalar::Util::looks_like_number($value)
        && $value > 1
        && $return->{"unit_long_pl"} )
    {
        $txt = '%value% %unit_long_pl%';
        $txt = $return->{"txt_format_long_pl"}
          if ( $return->{"txt_format_long_pl"} );
    }

    # long singular
    elsif ( $format && $return->{"unit_long"} ) {
        $txt = '%value% %unit_long%';
        $txt = $return->{"txt_format_long"}
          if ( $return->{"txt_format_long"} );
    }

    # short
    else {
        $txt = '%value% %unit%';
        $txt = $return->{"txt_format"} if ( $return->{"txt_format"} );
    }

    foreach my $k ( keys %{$return} ) {
        $txt =~ s/%$k%/$return->{$k}/g;
    }

    return $txt;
}

# Get reading short name from reading name
sub GetShortReadingname($) {
    my ($reading) = @_;
    my $r = lc($reading);

    if ( $readingsDB{$r}{"short"} ) {
        return $readingsDB{$r}{"short"};
    }
    elsif ( $readingsDB{$r}{"unified"} ) {
        my $dr = $readingsDB{$r}{"unified"};
        return $readingsDB{$dr}{"short"};
    }

    return $reading;
}

1;