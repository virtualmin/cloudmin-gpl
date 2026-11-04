use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use WebminCore qw(convert_from_json read_file_contents);
require "$Bin/../lib/Cloudmin/VMs.pm";

# Run generated first-boot commands with isolated stubs, never host services.
my $dir = tempdir(CLEANUP => 1);
my %commands = (
    getsebool => 'exit "$TEST_POLICY_MISSING"',
    setsebool => 'echo "policy $*" >> "$TEST_AGENT_LOG"; exit "$TEST_POLICY_FAILURE"',
    systemctl => <<'SH',
case "$1" in
    show) echo loaded ;;
    is-enabled) echo enabled ;;
    start) echo "agent $*" >> "$TEST_AGENT_LOG" ;;
esac
SH
);
foreach my $command (keys %commands) {
    # Every external command resolves to a fixture executable.
    open(my $file, '>', "$dir/$command") || die $!;
    print $file "#!/bin/sh\n$commands{$command}\n";
    close($file) || die $!;
    chmod(0700, "$dir/$command") || die $!;
}

# Agent SSH permissions must be prepared even without initial SSH keys.
for my $auth (qw(password keys)) {
    my $seed = Cloudmin::VMs::seed_data({ username => 'fixture',
        auth_type => $auth, password_hash => 'fixture', hostname => 'fixture',
        address_mode => 'dhcp', mac => '52:54:00:00:00:01', software => 'none' }, 'fixture');
    $seed->{'user-data'} =~ s/^#cloud-config\n//;
    my $data = convert_from_json($seed->{'user-data'});
    open(my $script, '>', "$dir/start.sh") || die $!;
    print $script $data->{'runcmd'}->[0]->[2];
    close($script) || die $!;
    # Exercise supported, absent and failing policy commands in isolation.
    foreach my $case ([0, 0, 'available'], [1, 0, 'unavailable'], [0, 1, 'denied']) {
        my ($missing, $failure, $name) = @$case;
        local $ENV{'PATH'} = $dir;
        local $ENV{'TEST_AGENT_LOG'} = "$dir/log";
        local $ENV{'TEST_POLICY_MISSING'} = $missing;
        local $ENV{'TEST_POLICY_FAILURE'} = $failure;
        unlink("$dir/log");
        # Inspect only the generated script status and the stub command log.
        my $status = system('/bin/sh', "$dir/start.sh");
        my $log = -e "$dir/log" ? read_file_contents("$dir/log") : '';
        is($status == 0 ? 1 : 0, $failure ? 0 : 1, "$auth: $name policy result");
        # Unsupported policies must not block ordinary agent startup.
        if ($missing) {
            unlike($log, qr/policy/, "$auth: absent SELinux policy is skipped");
            like($log, qr/agent start/, "$auth: agent still starts");
        }
        elsif ($failure) {
            # Do not report successful setup when the permission change fails.
            unlike($log, qr/agent start/, "$auth: failed policy change stops setup");
        }
        else {
            # Only SSH key management is enabled, persistently, before startup.
            is($log, "policy -P virt_qemu_ga_manage_ssh on\nagent start qemu-guest-agent.service\n",
                "$auth: SSH permission is ready before the agent starts");
        }
    }
}
done_testing();
