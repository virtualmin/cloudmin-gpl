#!/usr/bin/perl
# cli.pl command [options] Host commands share the JSON API; help and docs need
# no running installation.
use strict;
use warnings;
use FindBin qw($Bin);
BEGIN {
    # Installed modules live inside Webmin; source checkouts use its sibling.
    my ($root) = grep {-r "$_/WebminCore.pm"}
        (defined($ENV{WEBMIN_ROOT}) ? ($ENV{WEBMIN_ROOT}) : ("$Bin/..", "$Bin/../webmin"));
    unshift(@INC,$root) if ($root);
}
use lib "$Bin/lib";
use Cloudmin::CLI;

# Help generation also runs in source builds on non-Linux workstations.
my $offline = !@ARGV || $ARGV[0] =~ /\A(?:help|--help|--docs|--docs-dir)\z/ || grep {$_ eq '--help'} @ARGV;
# Host operations require root on Linux even when the wrapper is bypassed.
if (!$offline && ($^O ne 'linux' || $< != 0)) {
    print STDERR "Run this command as root on the Cloudmin Linux host\n";
    exit(2);
}
my $loaded;
# bootstrap() loads the same root identity and module context as api.pl.
sub bootstrap
{
    # Initialize the module only once per invocation.
    return if ($loaded);
    # Host commands use root identity and installed paths, independent of cwd.
    $ENV{'WEBMIN_CONFIG'} ||= '/etc/webmin';
    $ENV{'WEBMIN_VAR'} ||= '/var/webmin';
    $ENV{'REMOTE_USER'} = 'root';
    $0 = "$FindBin::Bin/$FindBin::Script";
    chdir($FindBin::Bin) || die $!;
    require './server-manager-lib.pl';
    $loaded = 1;
}
# Read-only actions do not need form tokens; the controller still checks access.
my %read = map {$_ => 1} Cloudmin::CLI::read_actions();
my $cli = Cloudmin::CLI->new(
    # api(action, input) dispatches requests without exposing tokens in output.
    api => sub {
        die "Run this command as root on the Cloudmin Linux host\n"
            unless $^O eq 'linux' && $< == 0;
        # Webmin failures must reach the CLI's JSON/error formatter too.
        local $main::error_must_die = 1;
        bootstrap();
        my ($action,$input) = @_;
        # Supply a form token for writes unless the caller provided one.
        $input->{token} ||= get_image_jobs()->form_token('root') if (!$read{$action});
        return call_vm_api(1,$action,$input);
    },
    # raw([action]) retains api.pl's stdin, token and output contracts exactly.
    raw => sub {
        exec($^X,"$Bin/api.pl",@_);
        die "Cannot run the raw API: $!\n";
    });
# Forward the dispatcher exit code for success, operation or usage failure.
exit($cli->run(\@ARGV));
