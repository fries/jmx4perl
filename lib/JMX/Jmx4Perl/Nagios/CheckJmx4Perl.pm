package JMX::Jmx4Perl::Nagios::CheckJmx4Perl;

use strict;
use warnings;
use JMX::Jmx4Perl;
use JMX::Jmx4Perl::Request;
use JMX::Jmx4Perl::Response;
use JMX::Jmx4Perl::Alias;
use Data::Dumper;
use Nagios::Plugin;
use Nagios::Plugin::Functions qw(:codes %STATUS_TEXT);
use Time::HiRes qw(gettimeofday tv_interval);
use Carp;
use Scalar::Util qw(looks_like_number);
use URI::Escape;
our $AUTOLOAD;

=head1 NAME

JMX::Jmx4Perl::CheckJmx4Perl - Module for encapsulating the functionality of
L<check_jmx4perl> 

=head1 SYNOPSIS

  # One line in check_jmx4perl to rule them all
  JMX::Jmx4Perl::CheckJmx4Perl->new()->execute();

=head1 DESCRIPTION

The purpose of this module is to encapsulate a single run of L<check_jmx4perl> 
in a perl object. This allows for C<check_jmx4perl> to run within the embedded
Nagios perl interpreter (ePN) wihout interfering with other, potential
concurrent, runs of this check. Please refer to L<check_jmx4perl> for
documentation on how to use this check. This module is probably I<not> of 
general interest and serves only the purpose described above.

=cut

sub new {
    my $class = shift;
    my $self = { 
                np => &_create_nagios_plugin(),
               };
    bless $self,(ref($class) || $class);
    $self->_verify_and_initialize();
    return $self;
}


sub execute {
    my $self = shift;
    my $np = $self->{np};
    eval {
        my $o = $self->{opts};

        # Request
        my @optional = ();
        if ($self->target) {
            push @optional,target => { 
                                      url => $self->target,
                                      $self->target_user ? (user => $self->target_user) : (),
                                      $self->target_password ? (password => $self->target_password) : (),
                                     }
        }
        my $jmx = JMX::Jmx4Perl->new(mode => "agent", url => $self->url, user => $self->user, 
                                     password => $self->password,
                                     product => $self->product, proxy => $self->proxy,
                                     @optional);
        my $request;
        my $do_read = $self->attribute || $self->value;
        if ($self->alias) {
            my $alias = JMX::Jmx4Perl::Alias->by_name($self->alias);
            die "No alias '",$self->alias," known" unless $alias;
            $do_read = $alias->type eq "attribute";
        }
        if ($do_read) {
            $request = JMX::Jmx4Perl::Request->new(READ,$self->_prepare_read_args($jmx));
        } else {
            $request = JMX::Jmx4Perl::Request->new(EXEC,$self->_prepare_exec_args($jmx,@ARGV));
        }
        
        my $resp = $self->_send_request($jmx,$request);
        my $value = $resp->value;
        # Delta handling
        my $delta = $self->delta;
        if (defined($delta)) {
            $value = $self->_delta_value($jmx,$request,$resp,$delta);
        }

        # Normalize value 
        my ($value_conv,$unit) = $self->_normalize_value($value);
        
        # Common args
        my $label = "'".$self->_get_name(cleanup => 1)."'";
        if ($self->base) {
            # Calc relative value 
            my $base_value = $self->_base_value($jmx,$self->base);
            my $rel_value = sprintf "%2.2f",(int((($value / $base_value) * 10000) + 0.5) / 100) ;


            # Performance data. Convert to absolute values before
            my ($critical,$warning) = $self->_convert_relative_to_absolute($base_value,$self->critical,$self->warning);
            $np->add_perfdata(label => $label,value => $value,
                              critical => $critical,warning => $warning,
                              min => 0,max => $base_value,
                              $self->unit ? (uom => $self->unit) : ());

            # Do the real check.
            my ($code,$mode) = $self->_check_threshhold($rel_value);
            my ($base_conv,$base_unit) = $self->_normalize_value($base_value);
            return $np->nagios_exit($code,$self->_exit_message(code => $code,mode => $mode,rel_value => $rel_value, 
                                                               value => $value_conv, unit => $unit,base => $base_conv, 
                                                               base_unit => $base_unit));            
        } else {
            # Performance data
            $np->add_perfdata(label => $label,
                              critical => $self->critical, warning => $self->warning,
                              value => $value,$self->unit ? (uom => $self->unit) : ());

            # Do the real check.
            my ($code,$mode) = $self->_check_threshhold($value);
            return $np->nagios_exit($code,$self->_exit_message(code => $code,mode => $mode,value => $value_conv, unit => $unit));                    }
    };
    if ($@) {
        # p1.pl, the executing script of the embedded nagios perl interpreter
        # uses this tag to catch an exit code of a plugin. We rethrow this
        # exception if we detect this pattern.
        if ($@ !~ /^ExitTrap:/) {
            $np->nagios_die("Error: $@");
        } else {
            die $@;
        }
    }
}

sub _get_name { 
    my $self = shift;
    my $args = { @_ };
    my $o = $self->{opts};
    my $name = $args->{name};
    if (!$name) {
        if ($self->name) {
            $name = $self->name;
        } else {
            # Default name
            $name = $self->alias ? 
          "[".$self->alias.($self->path ? "," . $self->path : "") ."]" : 
            $self->value ? 
              "[" . $self->value . "]" :
            "[".$self->mbean.",".$self->attribute.($self->path ? "," . $self->path : "")."]";
        }
    }
    if ($args->{cleanup}) {
        # Enable this when '=' gets forbidden
        $name =~ s/=/#/g;
    }
    return $name;
}

sub _send_request {
    my ($self,$jmx,$request) = @_;
    my $o = $self->{opts};

    my $start_time;    
    if ($o->verbose) {
        print "Request URL: ",$jmx->request_url($request),"\n";
        if ($self->user) {
            print "Remote User: ",$o->user,"\n";
        }
        $start_time = [gettimeofday];
    }

    my $resp = $jmx->request($request);
    $self->_verify_response($resp);

    if ($o->verbose) {
        print "Result fetched in ",tv_interval($start_time) * 1000," ms:\n";
        print Dumper($resp);
    }

    return $resp;
}

sub _switch_on_history {
    my ($self,$jmx,$orig_request) = @_;
    my ($mbean,$operation) = $jmx->resolve_alias(JMX4PERL_HISTORY_MAX_ATTRIBUTE);
    # Set history to 1 (we need only the last)
    my $target = $jmx->cfg("target");
    my $switch_request = new JMX::Jmx4Perl::Request
      (EXEC,$mbean,$operation,
       $orig_request->get("mbean"),$orig_request->get("attribute"),$orig_request->get("path"),
       $target ? $target->{url} : undef,1,{target => undef});
    my $resp = $jmx->request($switch_request);
    if ($resp->is_error) {
        $self->{np}->nagios_die("Error: ".$resp->status." ".$resp->error_text.
                                "\nStacktrace:\n".$resp->stacktrace);
    }

    # Refetch value to initialize the history
    $resp = $jmx->request($orig_request);
    $self->_verify_response($resp);
}

sub _prepare_read_args {
    my $self = shift;
    my $np = $self->{np};
    my $jmx = shift;

    if ($self->alias) {
        my @req_args = $jmx->resolve_alias($self->alias);
        $np->nagios_die("Cannot resolve attribute alias ",$self->alias()) unless @req_args > 0;
        if ($self->path) {
            @req_args == 2 ? $req_args[2] = $self->path : $req_args[2] .= "/" . $self->path;
        }
        return @req_args;
    } elsif ($self->value) {
        return $self->_split_attr_spec($self->value);
    } else {
        return ($self->mbean,$self->attribute,$self->path);
    }
}

sub _prepare_exec_args {
    my $self = shift;
    my $np = $self->{np};
    my $jmx = shift;
    my @args = @_;

    if ($self->alias) {
        my @req_args = $jmx->resolve_alias($self->alias);
        $np->nagios_die("Cannot resolve operation alias ",$self->alias()) unless @req_args >= 2;
        return (@req_args,@args);
    } else {
        return ($self->mbean,$self->operation,@args);
    }
}

sub _verify_response {
    my ($self,$resp) = @_;
    my $np = $self->{np};
    if ($resp->is_error) {
        $np->nagios_die("Error: ".$resp->status." ".$resp->error_text."\nStacktrace:\n".$resp->stacktrace);
    }
    if (!defined($resp->value)) {
        $np->nagios_die("JMX Request " . $self->_get_name() . 
                        " returned a null value which can't be used yet. " . 
                        "Please let me know, whether you need such check for a null value");
    }
    if (ref($resp->value)) { 
        $np->nagios_die("Response value is a ".ref($resp->value).
                        ", not a plain value. Did you forget a --path parameter ?","Value: " . 
                        Dumper($resp->value));
    }
}

sub _verify_and_initialize { 
    my $self = shift;
    my $np = $self->{np};
    my $o = $np->opts;
    
    $self->{opts} = $self->{np}->opts;

    # Fetch configuration
    my $config = $self->_get_config($o->config);
    
    # Now, if a specific check is given, extract it, too.
    if ($o->check) {
        $np->nagios_die("No configuration given") unless $config;
        $np->nagios_die("No checks defined in configuration") unless $config->{check};
        
        $self->{check_config} = $config->{check}->{$o->check};
        unless ($self->{check_config}) {
            # Try it as a multi check
            my $multi_checks = $config->{multicheck};
            if ($multi_checks)  {
                my $m_check = $multi_checks->{$o->check};
                if ($m_check && $m_check->{check}) {
                    # Resolve all check;
                    my $c_names = ref($m_check->{check}) eq "ARRAY" ? $m_check->{check} : [ $m_check->{check} ];
                    for my $c_name (@$c_names) {
                        my $check = $config->{check}->{$c_name} ||
                          $np->nagios_die("Unknown check '" . $c_name . "' for multi check " . $o->check);
                        push @{$self->{multi_check}},$check;
                    }
                    print Dumper($self->{multi_check});
                }
            }
        }

        $np->nagios_die("Invalid configuration for " . $o->check . ":\n" . Dumper($self->{check_config})) 
          unless ref($self->{check_config}) eq "HASH";
        $np->nagios_die("No check configuration with name " . $o->check . " found")
          if (!$self->{check_config} && !$self->{multi_check});
    }
    
    # If a server name is given, we use that for the connection parameters
    if ($o->server) {
        $self->{server_config} = $config->get_server_config($o->server)
          || $np->nagios_die("No server configuration for " . $o->server . " found");
    } 

    # Sanity checks
    $np->nagios_die("No Server URL given") unless $self->url;

    $np->nagios_die("An MBean name and a attribute/operation must be provided (or a check name from the configuration)")
      if ((!$self->mbean || (!$self->attribute && !$self->operation)) && !$self->alias && !$self->value);
    
    $np->nagios_die("At least a critical or warning threshold must be given") 
      if ((!defined($self->critical) && !defined($self->warning)));    
}

sub _get_config {
    my $self = shift;
    my $path = shift;
    my $np = $self->{np};
    $np->nagios_die("No configuration file " . $path . " found")
      if ($path && ! -e $path);
    return new JMX::Jmx4Perl::Config($path);
}

sub _server_config {
    return shift->{server_config};
}

sub _check_config {
    return shift->{check_config};
}

sub _delta_value {
    my ($self,$jmx,$request,$resp,$delta) = @_;
    
    my $history = $resp->history;
    if (!$history) {
        $self->_switch_on_history($jmx,$request);           
        # No delta on the first run
        return 0;
    } else {
        my $old_value = $history->[0]->{value};
        my $old_time = $history->[0]->{timestamp};
        if ($delta) {
            return (($resp->value - $old_value) / ($resp->timestamp - $old_time)) * $delta;
        } else {
            return $resp->value - $old_value;
        }
    }    
}

sub _convert_relative_to_absolute { 
    my $self = shift;
    my ($base_value,@to_convert) = @_;
    my @ret = ();
    for my $v (@to_convert) {
        $v =~ s|([\d\.]+)|($1 / 100) * $base_value|eg if $v;
        push @ret,$v;
    }
    return @ret;
}

sub _base_value {
    my $self = shift;
    my $np = $self->{np};
    my $jmx = shift;
    my $name = shift;

    if (looks_like_number($name)) {
        # It looks like a number, so we suppose its  the base value itself
        return $name;
    }

    my $alias = JMX::Jmx4Perl::Alias->by_name($name);
    my $request;
    if ($alias) {
        $request = new JMX::Jmx4Perl::Request(READ,$jmx->resolve_alias($name));
    } else {
        my ($mbean,$attr,$path) = $self->_split_attr_spec($name);
        die "No MBean given in base name ",$name unless $mbean;
        die "No Attribute given in base name ",$name unless $attr;
        
        $mbean = URI::Escape::uri_unescape($mbean);
        $attr = URI::Escape::uri_unescape($attr);
        $path = URI::Escape::uri_unescape($path) if $path;
        $request = new JMX::Jmx4Perl::Request(READ,$mbean,$attr,$path);
    }

    my $resp = $self->_send_request($jmx,$request);
    die "Base value is not a plain value but ",Dumper($resp->value) if ref($resp->value);
    return $resp->value;
}

sub _split_attr_spec {
    my $self = shift;
    my $name = shift;

    # TODO: Implement escaping
    return split m|/|,$name;
}

sub _check_threshhold {
    my $self = shift;
    my $value = shift;
    my $np = $self->{np};
    my $o = $self->{opts};
    my $numeric_check;
    if ($self->numeric || $self->string) {
        $numeric_check = $self->numeric ? 1 : 0;
    } else {
        $numeric_check = looks_like_number($value);
    }
    if ($numeric_check) {
        # Verify numeric thresholds
        my @ths = 
          (
           $self->critical ? (critical => $self->critical) : (),
           $self->warning ? (warning => $self->warning) : ()
          );            
        return ($np->check_threshold(check => $value,@ths),"numeric");    
    } else {
        return
          ($self->_check_string_threshold($value,CRITICAL,$self->critical) ||
            $self->_check_string_threshold($value,WARNING,$self->warning) ||
              OK,
           $value =~ /^true|false$/i ? "boolean" : "string");
    }
}

sub _check_string_threshold {
    my $self = shift;
    my ($value,$level,$check_value) = @_;
    return undef unless $check_value;
    if ($check_value =~ m|^\s*qr(.)(.*)\1\s*$|) {
        return $value =~ m/$2/ ? $level : undef;
    }
    if ($check_value =~ s/^\!//) {
        return $value ne $check_value ? $level : undef; 
    } else {
        return $value eq $check_value ? $level : undef;
    }    
}


# =========================================================================================== 
  
# Prepare an exit message depending on the result of
# the check itself. Quite evolved, you can overwrite this always via '--label'.
sub _exit_message {
    my $self = shift;
    my $args = { @_ };       
    my $o = $self->{opts};
    # Custom label has precedence
    return $self->_format_label($self->label,$args) if $self->label;

    my $code = $args->{code};
    my $mode = $args->{mode};
    if ($code == CRITICAL || $code == WARNING) {
        if ($self->base) {
            return $self->_format_label
              ('%n : Threshold \'%t\' failed for value %.2r% ('. &_placeholder($args,"v") .' %u / '.
               &_placeholder($args,"b") . ' %u)',$args);
        } else {
            if ($mode ne "numeric") {
                return $self->_format_label('%n : \'%v\' matches threshold \'%t\'',$args);
            } else {
                return $self->_format_label
                  ('%n : Threshold \'%t\' failed for value '.&_placeholder($args,"v").' %u',$args);
            }
        }
    } else {
        if ($self->base) {
            return $self->_format_label('%n : In range %.2r% ('. &_placeholder($args,"v") .' %u / '.
                                        &_placeholder($args,"b") . ' %w)',$args);
        } else {
            if ($mode ne "numeric") {
                return $self->_format_label('%n : \'%v\' as expected',$args);
            } else {
                return $self->_format_label('%n : Value '.&_placeholder($args,"v").' %u in range',$args);
            }
        }

    }
}

sub _placeholder {
    my ($args,$c) = @_;
    my $val;
    if ($c eq "v") {
        $val = $args->{value};
    } else {
        $val = $args->{base};
    }
    return ($val =~ /\./ ? "%.2" : "%") . $c;
}

sub _format_label {
    my $self = shift;
    my $label = shift;
    my $args = shift;
    my $o = $self->{opts};
    # %r : relative value
    # %v : value
    # %u : unit
    # %b : base value
    # %t : threshold failed ("" for OK or UNKNOWN)
    # %c : code ("OK", "WARNING", "CRITICAL", "UNKNOWN")

    my @parts = split /(\%[\w\.\-]*\w)/,$label;
    my $ret = "";
    foreach my $p (@parts) {
        if ($p =~ /^(\%[\w\.\-]*)(\w)$/) {
            my ($format,$what) = ($1,$2);
            if ($what eq "r") {
                $ret .= sprintf $format . "f",($args->{rel_value} || 0);
            } elsif ($what eq "b") {
                $ret .= sprintf $format . &_format_char($args->{base}),($args->{base} || 0);
            } elsif ($what eq "u" || $what eq "w") {
                $ret .= sprintf $format . "s",($what eq "u" ? $args->{unit} : $args->{base_unit}) || "";
                $ret =~ s/\s$//;
            } elsif ($what eq "v") {
                if ($args->{mode} ne "numeric") {
                    $ret .= sprintf $format . "s",$args->{value};
                } else {
                    $ret .= sprintf $format . &_format_char($args->{value}),$args->{value};
                }
            } elsif ($what eq "t") {
                my $code = $args->{code};
                $ret .= sprintf $format . "s",$code == CRITICAL ? $self->critical : ($code == WARNING ? $self->warning : "");
            } elsif ($what eq "c") {
                $ret .= sprintf $format . "s",$STATUS_TEXT{$args->{code}};
            } elsif ($what eq "n") {
                $ret .= sprintf $format . "s",$self->_get_name();
            }
        } else {
            $ret .= $p;
        }
    }
    return $ret;
}

sub _format_char {
    my $val = shift;
    $val =~ /\./ ? "f" : "d";
}


# =========================================================================================== 

# Units and how to convert from one level to the next
my @UNITS = ([ qw(us ms s m h d) ],[qw(B KB MB GB TB)]);
my %UNITS = 
  (
   us => 10**3,
   ms => 10**3,
   s => 1,
   m => 60,
   h => 60,
   d => 24,

   B => 1,
   KB => 2**10,
   MB => 2**10,
   GB => 2**10,
   TB => 2**10   
  );

# Normalize value if a unit-of-measurement is given.
sub _normalize_value {
    my $self = shift;
    my $value = shift;
    my $o = $self->{opts};
    my $unit = shift || $self->{unit} || return ($value,undef);
    
    for my $units (@UNITS) {
        for my $i (0 .. $#{$units}) {
            next unless $units->[$i] eq $unit;
            my $ret = $value;
            my $u = $unit;
            if ($ret > 1) {
                # Go up the scale ...
                return ($value,$unit) if $i == $#{$units};
                for my $j ($i+1 .. $#{$units}) {
                    if ($ret / $UNITS{$units->[$j]} >= 1) {                    
                        $ret /= $UNITS{$units->[$j]};
                        $u = $units->[$j];
                    } else {
                        return ($ret,$u);
                    }
                }             
            } else {
                # Go down the scale ...
                return ($value,$unit) if $i == 0;
                for my $j (reverse(0 .. $i-1)) {
                    if ($ret <= 1) {     
                        $ret *= $UNITS{$units->[$j+1]};
                        $u = $units->[$j];
                    } else {
                        return ($ret,$u);
                    }
                }
                
            }
            return ($ret,$u);
        }
    }
    die "Unknown unit '$unit' for value $value";
}

# =========================================================================================== 

sub _create_nagios_plugin {
    my $args = shift;
    my $np = Nagios::Plugin->
      new(
          usage => 
          "Usage: %s -u <agent-url> -m <mbean> -a <attribute> -c <threshold critical> -w <threshold warning> -n <label>\n" . 
          "                      [--alias <alias>] [--base <alias/number/mbean>] [--delta <time-base>] [--product <product>]\n".
          "                      [--user <user>] [--password <password>] [--proxy <proxy>]\n" .
          "                      [--target <target-url>] [--target-user <user>] [--target-password <password>]\n" .
          "                      [-v] [--help]",
          version => $JMX::Jmx4Perl::VERSION,
          url => "http://www.consol.com/opensource/nagios/",
          plugin => "check_jmx4perl",
          blurb => "This plugin checks for JMX attribute values on a remote Java application server",
          extra => "\n\nYou need to deploy j4p.war on the target application server or as an intermediate proxy.\n" .
          "Please refer to the documentation for JMX::Jmx4Perl for further details"
         );
    $np->shortname(undef);
    $np->add_arg(
                 spec => "url|u=s",
                 help => "URL to agent web application (e.g. http://server:8080/j4p/)",
                );
    $np->add_arg(
                 spec => "product=s",
                 help => "Name of app server product. (e.g. \"jboss\")",
                );
    $np->add_arg(
                 spec => "alias=s",
                 help => "Alias name for attribte (e.g. \"MEMORY_HEAP_USED\")",
                );
    $np->add_arg(
                 spec => "mbean|m=s",
                 help => "MBean name (e.g. \"java.lang:type=Memory\")",
        );
    $np->add_arg(
                 spec => "attribute|a=s",
                 help => "Attribute name (e.g. \"HeapMemoryUsage\")",
                );
    $np->add_arg(
                 spec => "operation|o=s",
                 help => "Operation to execute",
                );
    $np->add_arg(
                 spec => "base|base-alias|b=s",
                 help => "Base alias name, which when given, interprets critical and warning values as relative in the range 0 .. 100%",
                );
    $np->add_arg(
                 spec => "delta|d:s",
                 help => "Switches on incremental mode. Optional argument are seconds used for normalizing. ",
                );
    $np->add_arg(
                 spec => "path|p=s",
                 help => "Inner path for extracting a single value from a complex attribute or return value (e.g. \"used\")",
                );
    $np->add_arg(
                 spec => "string",
                 help => "Force string comparison for critical and warning checks"
                );
    $np->add_arg(
                 spec => "numeric",
                 help => "Force numeric comparison for critical and warning checks"
                );
    $np->add_arg(
                 spec => "critical|c=s",
                 help => "Critical Threshold for value. " . 
                 "See http://nagiosplug.sourceforge.net/developer-guidelines.html#THRESHOLDFORMAT " .
                 "for the threshold format.",
                );
    $np->add_arg(
                 spec => "warning|w=s",
                 help => "Warning Threshold for value.",
                );
    $np->add_arg(
                 spec => "target=s",
                 help => "JSR-160 Service URL specifing the target server"
                );
    $np->add_arg(
                 spec => "target-user=s",
                 help => "Username to use for JSR-160 connection (if --target is set)"
                );
    $np->add_arg(
                 spec => "target-password=s",
                 help => "Password to use for JSR-160 connection (if --target is set)"
                );
    $np->add_arg(
                 spec => "proxy=s",
                 help => "Proxy to use"
                );
    $np->add_arg(
                 spec => "user=s",
                 help => "User for HTTP authentication"
                );
    $np->add_arg(
                 spec => "password=s",
                 help => "Password for HTTP authentication"
                );
    $np->add_arg(
                 spec => "name|n=s",
                 help => "Name to use for output. Optional, by default a standard value based on the MBean ".
                 "and attribute will be used"
                );
    $np->add_arg(
                 spec => "unit=s",
                 help => "Unit of measurement of the data retreived. Recognized values are [B|KB|MN|GB|TB] for memory values and [us|ms|s|m|h|d] for time values"
                );
    $np->add_arg(
                 spec => "label|l=s",
                 help => "Label to be used for printing out the result of the check. Placeholders can be used."
                );
    $np->add_arg(
                 spec => "config=s",
                 help => "Path to configuration file. Default: ~/.j4p"
                );
    $np->add_arg(
                 spec => "server=s",
                 help => "Symbolic name of server url to use, which needs to be configured in the configuration file"                 
                );
    $np->add_arg(
                 spec => "check=s",
                 help => "Name of a check configuration as defined in the configuration file"
                );
    $np->getopts();
    return $np;
}

# Access to configuration informations
# Known config options (key: cmd line arguments, values: keys in config);
my $SERVER_CONFIG_KEYS = {
                          "url" => "url",
                          "target" => "target",
                          "user" => "user",
                          "password" => "password",
                          "product" => "product",
                          "target_user" => "target/user",
                          "target_password" => "target/password",
                          "target_url" => "target/url",
                          "proxy" => "proxy",
                          "proxy_url" => "proxy/url",
                          "proxy_user" => "proxy/user",
                          "proxy_password" => "proxy/password"
                         };

my $CHECK_CONFIG_KEYS = {
                         "critical" => "critical",
                         "warning" => "warning",
                         "mbean" => "mbean",
                         "attribute" => "attribute",
                         "operation" => "operation",
                         "alias" => "alias",        
                         "path" => "path",
                         "delta" => "delta",
                         "name" => "name",
                         "base" => "base",
                         "unit" => "unit",
                         "numeric" => "numeric",
                         "string" => "string",
                         "label" => "label",
                         # New:
                         "value" => "value"
                        };

sub AUTOLOAD {
    my $self = shift;
    my $np = $self->{np};
    my $name = $AUTOLOAD;
    $name =~ s/.*://;   # strip fully-qualified portion
    $name =~ s/-/_/g;

    if ($SERVER_CONFIG_KEYS->{$name}) {        
        return $np->opts->{$name} if $np->opts->{$name};
        my $c = $SERVER_CONFIG_KEYS->{$name};
        if ($c) {
            my @parts = split "/",$c;
            my $h = $self->_server_config ||
              return undef;
            while (@parts) {
                my $p = shift @parts;
                return undef unless $h->{$p};
                $h = $h->{$p};
                return $h unless @parts;
            }
        } else {
            return undef;
        }
    } elsif ($CHECK_CONFIG_KEYS->{$name}) {
        return $np->opts->{$name} || 
          $self->_check_config->{$CHECK_CONFIG_KEYS->{$name}};
    } else {
        $np->nagios_die("No config attribute \"" . $name . "\" known");
    }
}

sub DESTROY {

}

=head1 LICENSE

This file is part of jmx4perl.

Jmx4perl is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 2 of the License, or
(at your option) any later version.

jmx4perl is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with jmx4perl.  If not, see <http://www.gnu.org/licenses/>.

=head1 AUTHOR

roland@cpan.org

=cut

1;
