"""Exercise the production Perl helpers with isolated files and child processes."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

# Fixtures may point at a private seed containing both the core and Pro helpers.
ROOT = Path(os.environ.get('CLOUDMIN_SOURCE', Path(__file__).resolve().parents[1]))
PRELUDE = r"""
use strict;
use warnings;
use JSON::PP;
require $ARGV[0];
require $ARGV[1];
my $data = decode_json(do { local $/; <STDIN> });
package Cloudmin::GuestSoftware;
no warnings qw(redefine once);
our ($DIRECTORY, $IDENTITY_DIRECTORY, $HOST_PUBLIC_KEY, $CONFIG, $UNIT);
$DIRECTORY = $data->{'directory'};
$IDENTITY_DIRECTORY = $data->{'directory'};
$HOST_PUBLIC_KEY = "$DIRECTORY/ssh_host_rsa_key.pub";
$UNIT = $data->{'unit'} if $data->{'unit'};
umask(0077);
"""

# run_perl(body, data, [timeout]) loads production routines without their CLI.
def run_perl(body, data, timeout=10):
    return subprocess.run(
        ['perl', '-e', PRELUDE + body, str(ROOT / 'guest-software.pl'),
         str(ROOT / 'software-worker.pl')],
        input=json.dumps(data), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        universal_newlines=True, timeout=timeout)


class SoftwareTests(unittest.TestCase):
    # setUp(self) keeps scripts, journals and fake commands in one private fixture.
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cloudmin-perl-', dir='/tmp')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.config = dict(software='virtualmin-pro', uuid='fixture',
                           virtualmin_bundle='LEMP', virtualmin_type='mini',
                           virtualmin_ssl='0', virtualmin_postgres='0')

    # invoke(self, body, [**values]) fails on Perl warnings as well as errors.
    def invoke(self, body, **values):
        result = run_perl(body, dict(directory=str(self.directory), config=self.config, **values))
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stderr, '')
        return result.stdout

    # save(self, name, value) writes a fixture journal or private request.
    def save(self, name, value):
        (self.directory / name).write_text(json.dumps(value))

    # status(self) reads the actual journal written by the Perl helper.
    def status(self):
        return json.loads((self.directory / 'status.json').read_text())

    # test_arguments(self) keeps the official installer's flags unchanged.
    def test_arguments(self):
        self.assertEqual(json.loads(self.invoke('report(arguments($data->{config}));')),
                         ['--bundle', 'LEMP', '--type', 'mini', '--yes', '--no-hostname-ssl'])

    # test_agent_policy(self) keeps distro restrictions while enabling public reads.
    def test_agent_policy(self):
        fixtures = [
            ('BLACKLIST_RPC="guest-file-open,guest-file-write,guest-file-read,guest-exec,guest-file-close"\n',
             'BLACKLIST_RPC="guest-file-write,guest-exec"\n'),
            ('FILTER_RPC_ARGS="--allow-rpcs=guest-ping,guest-info"\n',
             'FILTER_RPC_ARGS="--allow-rpcs=guest-ping,guest-info,guest-file-open,guest-file-read,guest-file-close"\n'),
            ('[general]\nblock-rpcs = guest-exec,guest-file-read\n',
             '[general]\nblock-rpcs = guest-exec\n'),
            ('# BLACKLIST_RPC="guest-file-read"\nFSFREEZE_HOOK_PATHNAME=/etc/qemu/fsfreeze-hook\n',
             '# BLACKLIST_RPC="guest-file-read"\nFSFREEZE_HOOK_PATHNAME=/etc/qemu/fsfreeze-hook\n'),
            ('allow-rpcs=guest-ping,guest-file-open,guest-file-read,guest-file-close\n',
             'allow-rpcs=guest-ping,guest-file-open,guest-file-read,guest-file-close\n'),
        ]
        for original, expected in fixtures:
            output = self.invoke('report({ policy => agent_policy($data->{policy}) });', policy=original)
            actual = json.loads(output)['policy']
            self.assertEqual(actual, expected)
            repeated = self.invoke('report({ policy => agent_policy($data->{policy}) });', policy=actual)
            self.assertEqual(json.loads(repeated)['policy'], expected)

    # test_prepare_identity(self) never reads or exports an SSH private key.
    def test_prepare_identity(self):
        self.config['uuid'] = '11111111-2222-4333-8444-555555555555'
        for existing in (False, True):
            # An existing host key must not trigger an unnecessary sshd reload.
            if existing:
                self.directory.joinpath('ssh_host_rsa_key.pub').write_text('existing public key')
            output = self.invoke(r'''
            my @calls;
            local *command = sub {
                push(@calls, $_[0]);
                return (0, "loaded\n") if $_[0]->[0] eq 'systemctl' && $_[0]->[1] eq 'show';
                return (0, '');
            };
            local *read_file = sub {
                return '' if $_[0] =~ m{\A/etc/(?:sysconfig/qemu-(?:ga|guest-agent)|qemu/qemu-ga\.conf)\z};
                die 'private key read' if $_[0] ne $HOST_PUBLIC_KEY;
                return "ssh-rsa Zml4dHVyZQ== guest\n";
            };
            prepare($data->{config});
            report(\@calls);
            ''')
            calls = json.loads(output)
            reload = ['systemctl', 'try-reload-or-restart', 'sshd.service']
            self.assertEqual(reload in calls, not existing)
            self.assertEqual(calls[-1], ['systemctl', 'restart', 'qemu-guest-agent.service'])
            identity = json.loads(self.directory.joinpath('cloudmin-identity.json').read_text())
            self.assertEqual(identity, dict(uuid=self.config['uuid'], key='ssh-rsa Zml4dHVyZQ== guest'))

    # test_service_units(self) covers installed aliases and SUSE template instances.
    def test_service_units(self):
        for unit in ('qemu-guest-agent.service', 'qemu-ga.service',
                     'qemu-ga@org.qemu.guest_agent.0.service', ''):
            output = self.invoke(r'''
            local *command = sub {
                my ($args) = @_;
                return (0, $data->{unit} ? "$data->{unit} loaded active running QEMU agent\n" : '')
                    if $args->[1] eq 'list-units';
                return (0, $args->[2] eq $data->{unit} ? "loaded\n" : "not-found\n");
            };
            report({unit => service_unit('qemu-guest-agent.service', 'qemu-ga.service', 'qemu-ga@*.service')});
            ''', unit=unit)
            self.assertEqual(json.loads(output)['unit'], unit or None)
        output = self.invoke(r'''
            local *command = sub { return (0, $_[0]->[2] eq 'ssh.service' ? "loaded\n" : "not-found\n") };
            report({unit => service_unit('sshd.service', 'ssh.service')});
        ''')
        self.assertEqual(json.loads(output)['unit'], 'ssh.service')

    # test_prepare_service_failure(self) must not accept unapplied SSH or agent changes.
    def test_prepare_service_failure(self):
        for failure in ('try-reload-or-restart', 'restart'):
            output = self.invoke(r'''
            local *read_file = sub { "ssh-rsa Zml4dHVyZQ== guest\n" };
            local *service_unit = sub { $_[0] };
            local *command = sub { return ($_[0]->[1] eq $data->{failure} ? 1 : 0, '') };
            eval { prepare($data->{config}) };
            report({error => "$@"});
            ''', failure=failure)
            self.assertIn('Cannot reload' if failure == 'try-reload-or-restart' else 'Cannot restart',
                          json.loads(output)['error'])

    # test_cleanup(self) makes absent files harmless without hiding real failures.
    def test_cleanup(self):
        self.invoke('write_file("$DIRECTORY/temp", "fixture"); remove_file("$DIRECTORY/temp");'
                    'remove_file("$DIRECTORY/temp");')
        self.assertFalse((self.directory / 'temp').exists())
        self.directory.joinpath('child').mkdir()
        output = self.invoke('eval { remove_file("$DIRECTORY/child") }; report({ failed => !!$@ });')
        self.assertTrue(json.loads(output)['failed'])

    # test_redaction(self) covers secrets crossing a read boundary and log limits.
    def test_redaction(self):
        secret = 'private-key'
        raw = secret + 'x' * 4070 + secret + 'x' * 4092 + secret
        self.directory.joinpath('input').write_text(raw)
        self.invoke('open(my $in, "<", "$DIRECTORY/input") or die;'
                    'open(my $out, ">", "$DIRECTORY/log") or die; redact($in, $out, ["private-key"]);')
        output = self.directory.joinpath('log').read_text()
        self.assertNotIn(secret, output)
        self.assertEqual(output.count('[redacted]'), 3)
        self.directory.joinpath('input').write_text('x' * (5 * 1024 * 1024))
        self.invoke('open(my $in, "<", "$DIRECTORY/input") or die;'
                    'open(my $out, ">", "$DIRECTORY/log") or die; redact($in, $out, []);')
        self.assertEqual(self.directory.joinpath('log').stat().st_size, 4 * 1024 * 1024)

    # test_unicode_script(self) preserves non-ASCII text from JSON through shell.
    @unittest.skipUnless((ROOT / 'guest-scripts.pl').is_file(), 'Pro guest helper is not installed')
    def test_unicode_script(self):
        self.config.update(software='none', before_script="printf '%s' 'Привет café 日本語'")
        self.save('status.json', dict(stage='queued'))
        self.save('request.json', {})
        self.invoke('install($data->{config});')
        self.assertEqual(self.status()['stage'], 'complete')
        self.assertIn('Привет café 日本語', self.directory.joinpath('install.log').read_text())

    # test_gpl_script_refusal(self) never silently skips script work after removal.
    @unittest.skipIf((ROOT / 'guest-scripts.pl').is_file(), 'Testing a Pro seed')
    def test_gpl_script_refusal(self):
        self.config.update(software='none', before_script='echo must-not-run')
        self.save('status.json', dict(stage='queued'))
        self.save('request.json', {})
        self.invoke('install($data->{config});')
        self.assertEqual(self.status()['stage'], 'failed')
        self.assertIn('require Cloudmin Pro', self.directory.joinpath('install.log').read_text())
        self.assertFalse(self.directory.joinpath('before_script.sh').exists())

    # test_packages(self) verifies command arguments without invoking a manager.
    def test_packages(self):
        for manager in ('apt-get', 'dnf', 'zypper'):
            output = self.invoke(
                'local *executable = sub { $_[0] eq $data->{manager} ? "/usr/bin/$_[0]" : undef };'
                'report(package_commands("curl jq"));', manager=manager)
            commands = json.loads(output)
            self.assertEqual(commands[-1][-3:], ['--', 'curl', 'jq'])
            self.assertTrue(all(c[0] == '/usr/bin/' + manager for c in commands))
            # Debian-family installs must wait for competing first-boot updates.
            if manager == 'apt-get':
                self.assertIn('DPkg::Lock::Timeout=600', commands[-1])
        for packages in ('--remove curl', 'curl;id', 'https://example/a.rpm', 'curl*', 'curl-'):
            output = self.invoke('eval { package_commands($data->{packages}) }; report({ failed => !!$@ });',
                                 packages=packages)
            self.assertTrue(json.loads(output)['failed'])

    # test_script(self) executes a real shell and preserves its failure semantics.
    @unittest.skipUnless((ROOT / 'guest-scripts.pl').is_file(), 'Pro guest helper is not installed')
    def test_script(self):
        self.config.update(software='none', username='cloudmin',
                           before_script='printf "%s" "$CLOUDMIN_GUEST_USER"\nfalse\necho must-not-run\n')
        self.save('status.json', dict(stage='queued'))
        self.save('request.json', {})
        self.invoke('install($data->{config});')
        self.assertEqual(self.status()['failed_step'], 'before')
        self.assertIn('cloudmin', self.directory.joinpath('install.log').read_text())
        self.assertNotIn('must-not-run', self.directory.joinpath('install.log').read_text())
        self.assertFalse(self.directory.joinpath('before_script.sh').exists())

    # test_order(self) stops after failure and never replays accepted work.
    @unittest.skipUnless((ROOT / 'guest-scripts.pl').is_file(), 'Pro guest helper is not installed')
    def test_order(self):
        self.config.update(software='none', packages='jq', before_script='true', after_script='true')
        for failure in ('', 'before', 'packages', 'after'):
            self.save('status.json', dict(stage='queued'))
            self.save('request.json', {})
            output = self.invoke(r'''
my @seen;
local *package_commands = sub { [['dnf', 'install', 'jq']] };
local *execute = sub {
    my $stage = status()->{stage};
    push(@seen, $stage);
    die "fixture failure\n" if ($stage eq $data->{failure});
};
install($data->{config});
install($data->{config});
report(\@seen);
''', failure=failure)
            expected = ['before', 'packages', 'after']
            self.assertEqual(json.loads(output), expected[:expected.index(failure) + 1] if failure else expected)
            self.assertEqual(self.status()['stage'], 'failed' if failure else 'complete')
            self.assertFalse(self.directory.joinpath('request.json').exists())

    # test_installer(self) uses an in-memory download fixture, never the network.
    def test_installer(self):
        for failure in (False, True):
            self.save('status.json', dict(stage='queued'))
            self.save('request.json', dict(serial='123456', key='private-key'))
            self.invoke(r'''
local *download = sub { "#!/bin/sh\nprintf 'license private-key serial 123456\\n'\nexit ".($data->{failure} ? 1 : 0)."\n" };
install($data->{config});
''', failure=failure)
            self.assertEqual(self.status()['stage'], 'failed' if failure else 'complete')
            log = self.directory.joinpath('install.log').read_text()
            self.assertNotIn('private-key', log)
            self.assertNotIn('123456', log)
            for name in ('request.json', 'installer.sh'):
                self.assertFalse(self.directory.joinpath(name).exists())

    # test_virtualmin_sequence(self) retains all steps and the Pro download method.
    @unittest.skipUnless((ROOT / 'guest-scripts.pl').is_file(), 'Pro guest helper is not installed')
    def test_virtualmin_sequence(self):
        self.save('status.json', dict(stage='queued'))
        self.save('request.json', dict(serial='123456', key='private-key'))
        self.config.update(packages='jq', before_script='true', after_script='true')
        output = self.invoke(r'''
my @seen;
local *execute = sub { push(@seen, status()->{stage}) };
local *package_commands = sub { [['dnf', 'install', 'jq']] };
local *download = sub {
    die "wrong endpoint" if $_[0] ne 'https://www.virtualmin.com/api/install' || !$_[2];
    die "missing credentials" if $_[1]->{Authorization} ne 'Basic '.encode_base64('123456:private-key', '');
    return "#!/bin/sh\nexit 0\n";
};
install($data->{config});
report(\@seen);
''')
        self.assertEqual(json.loads(output), ['before', 'packages', 'install', 'after'])
        self.assertEqual(self.status()['completed'], ['before', 'packages', 'download', 'install', 'after'])

    # test_download(self) exercises HTTP requests, explicit TLS and safe redirects.
    def test_download(self):
        output = self.invoke(r'''
my @seen;
local *HTTP::Tiny::request = sub {
    my ($self, $method, $url, $options) = @_;
    die "unsafe TLS" if !$self->{verify_SSL} || $self->{max_redirect};
    push(@seen, [$method, $url]);
    return shift(@{$data->{responses}});
};
my $contents = download('https://www.virtualmin.com/api/install', {Authorization => 'Basic fixture'}, 1);
report({contents => $contents, requests => \@seen});
''', responses=[dict(status=307, headers={'location': '/api/installer'}),
                dict(status=200, success=True, content='#!/bin/sh\n')])
        self.assertEqual(json.loads(output)['requests'],
                         [['POST', 'https://www.virtualmin.com/api/install'],
                          ['POST', 'https://www.virtualmin.com/api/installer']])
        for location in ('https://other.example/install', 'http://www.virtualmin.com/install',
                         'https://www.virtualmin.com:444/install', 'https://user@www.virtualmin.com/install'):
            result = self.invoke(
                'eval { redirect_url("https://www.virtualmin.com/api/install", $data->{location}, 1) };'
                'report({failed => !!$@});', location=location)
            self.assertTrue(json.loads(result)['failed'])

    # test_download_failure(self) retains private diagnostics and removes secrets.
    def test_download_failure(self):
        for response in (dict(status=403), dict(status=599, content='fixture TLS failure private-key')):
            self.save('status.json', dict(stage='queued'))
            self.save('request.json', dict(serial='123456', key='private-key'))
            self.invoke('local *HTTP::Tiny::request = sub { $data->{response} }; install($data->{config});',
                        response=response)
            self.assertEqual(self.status()['failed_step'], 'download')
            self.assertNotIn('private-key', self.directory.joinpath('install.log').read_text())
            self.assertFalse(self.directory.joinpath('request.json').exists())

    # watch(self, [setup], [**values]) feeds the bounded watch protocol.
    # setup defaults to no overrides; values supplies optional fixture inputs.
    def watch(self, setup='', **values):
        request = values.pop('request', {'uuid': 'fixture'})
        return self.invoke(r'''
local *executable = sub { "/usr/bin/$_[0]" };
local *command = sub { (0, "ActiveState=inactive\nJob=\n") };
local *sleep = sub {};
my $raw = encode_json($data->{request});
open(my $input, "<", \$raw) or die;
local *STDIN = $input;
''' + setup + r'''
my $ok = eval { watch($data->{config}); 1 };
report({stage => 'failed', reason => ref($@) ? $@->{reason} : 'helper'}) if !$ok;
''', request=request, **values)

    # test_reconnect(self) rejects new work after a completed setup.
    def test_reconnect(self):
        self.save('status.json', dict(stage='complete'))
        output = self.watch()
        self.assertEqual(json.loads(output.splitlines()[-1]), {'stage': 'complete'})
        self.assertFalse(self.directory.joinpath('request.json').exists())

    # test_prerequisites(self) reports permanent setup failures without retrying.
    def test_prerequisites(self):
        for setup, request, reason in [
            ('', {'uuid': 'wrong'}, 'identity'),
            ('local *command = sub { (1, "") };', {'uuid': 'fixture'}, 'cloud_init_failed'),
            ("local *command = sub { fail('timeout') };", {'uuid': 'fixture'}, 'cloud_init_timeout'),
            ("local *executable = sub { $_[0] eq 'systemctl' ? '/bin/systemctl' : undef };",
             {'uuid': 'fixture'}, 'cloud_init_missing'),
            ('', {'uuid': 'fixture'}, 'credentials')]:
            output = self.watch(setup, request=request)
            self.assertEqual(json.loads(output.splitlines()[-1]), {'stage': 'failed', 'reason': reason})

    # test_interrupted(self) retains completed steps and does not replay work.
    def test_interrupted(self):
        self.save('status.json', dict(stage='packages', completed=['before']))
        self.save('request.json', dict(key='private-key'))
        self.watch()
        self.assertEqual(self.status(), dict(stage='failed', failed_step='packages', completed=['before']))
        self.assertFalse(self.directory.joinpath('request.json').exists())
        self.invoke('local *provision = sub { die "must not replay" }; install($data->{config});')

    # test_completion_race(self) preserves a journal written while systemd is queried.
    def test_completion_race(self):
        self.save('status.json', dict(stage='install'))
        self.watch(r'''
local *command = sub {
    save('status.json', {stage => 'complete'}) if $_[0]->[0] eq 'systemctl';
    return (0, "ActiveState=inactive\nJob=\n");
};
''')
        self.assertEqual(self.status()['stage'], 'complete')

    # test_queued_service(self) permits systemd to finish ordering startup.
    def test_queued_service(self):
        self.save('status.json', dict(stage='queued'))
        self.watch(r'''
local *command = sub {
    save('status.json', {stage => 'complete'}) if $_[0]->[1] eq 'show';
    return (0, "ActiveState=inactive\nJob=123\n");
};
''')
        self.assertEqual(self.status()['stage'], 'complete')

    # test_cancel(self) requires stopping the service and prevents later replay.
    def test_cancel(self):
        self.save('status.json', dict(stage='before', completed=[]))
        self.save('request.json', dict(key='private-key'))
        output = self.watch(r'''
local *command = sub {
    die "wrong stop" if join(' ', @{$_[0]}) ne "systemctl stop $UNIT";
    return (0, '');
};
''', request=dict(uuid='fixture', action='cancel'))
        self.assertEqual(json.loads(output)['stage'], 'cancelled')
        self.assertFalse(self.directory.joinpath('request.json').exists())
        self.assertEqual(json.loads(self.watch().splitlines()[-1])['stage'], 'cancelled')
        self.invoke('local *provision = sub { die "must not replay" }; install($data->{config});')

    # test_cancel_before_acceptance(self) blocks a delayed first watcher.
    def test_cancel_before_acceptance(self):
        self.watch(request=dict(uuid='fixture', action='cancel'))
        self.watch()
        self.assertEqual(self.status()['stage'], 'cancelled')
        self.assertFalse(self.directory.joinpath('request.json').exists())

    # test_no_systemd(self) fails unsupported guest setup promptly.
    def test_no_systemd(self):
        self.watch('local *executable = sub { undef };')
        self.assertEqual(self.status()['stage'], 'failed')
        self.assertIn('requires systemd', self.directory.joinpath('install.log').read_text())

    # test_command_timeout(self) checks a real child is stopped at the deadline.
    def test_command_timeout(self):
        output = self.invoke(
            'eval { command(["/bin/sleep", "30"], 1) }; report({reason => ref($@) ? $@->{reason} : ""});')
        self.assertEqual(json.loads(output)['reason'], 'timeout')

    # test_ssh_protocol(self) tests streams and failures using a local fake SSH.
    def test_ssh_protocol(self):
        for response, code, stage, reason in [
            ('', 255, 'unavailable', None), ('', 1, 'failed', 'helper'),
            ('{"stage":"failed","reason":"perl"}\n', 1, 'failed', 'perl'),
            ('{"stage":"failed","reason":"private-key"}\n', 1, 'failed', None),
            ('{"stage":"accepted"}\n{"stage":"complete"}\n', 0, 'complete', None),
            ('{"stage":"cancelled"}\n', 0, 'cancelled', None)]:
            fake = self.directory / 'ssh'
            fake.write_text("#!/bin/sh\n/bin/cat > received\nprintf '%s' " + shlex.quote(response) +
                            "\nexit " + str(code) + "\n")
            fake.chmod(0o700)
            output = self.invoke(r'''
chdir($DIRECTORY) or die;
my $result = Cloudmin::SoftwareWorker::monitor([$data->{fake}], {key => 'private-key'}, 5);
report($result);
''', fake=str(fake))
            self.assertEqual(json.loads(output.splitlines()[-1]),
                             dict(stage=stage, reason=reason, failed_step=None))
            self.assertNotIn('private-key', output)
            self.assertEqual(json.loads(self.directory.joinpath('received').read_text()), {'key': 'private-key'})

    # test_ssh_stderr(self) discards verbose SSH errors without exposing them.
    def test_ssh_stderr(self):
        fake = self.directory / 'ssh'
        fake.write_text('#!/bin/sh\n/bin/cat >/dev/null\n'
                        'i=0; while [ "$i" -lt 10000 ]; do printf "private-error\\n" >&2; i=$((i+1)); done\n'
                        'printf \'%s\\n\' \'{"stage":"complete"}\'\n')
        fake.chmod(0o700)
        output = self.invoke(
            'report(Cloudmin::SoftwareWorker::monitor([$data->{fake}], {key => "private-key"}, 5));',
            fake=str(fake))
        self.assertEqual(json.loads(output.splitlines()[-1])['stage'], 'complete')
        self.assertNotIn('private-error', output)

    # test_ssh_identity(self) preserves host-key pinning and rejects invalid targets.
    def test_ssh_identity(self):
        request = dict(address='192.0.2.5', username='cloudmin',
                       uuid='11111111-2222-4333-8444-555555555555',
                       host_public_key='ssh-rsa Zml4dHVyZQ==', key='private-key')
        output = self.invoke('chdir($DIRECTORY) or die; report(Cloudmin::SoftwareWorker::ssh_command($data->{request}));',
                             request=request)
        command = json.loads(output)
        self.assertIn('StrictHostKeyChecking=yes', command)
        self.assertIn('HostKeyAlias=' + request['uuid'], command)
        self.assertNotIn('private-key', output)
        self.assertEqual(self.directory.joinpath('known_hosts').read_text(),
                         request['uuid'] + ' ' + request['host_public_key'] + '\n')
        for address in ('--option', '192.0.2.5;id', 'host.example'):
            output = self.invoke('eval { Cloudmin::SoftwareWorker::ssh_command($data->{request}) };'
                                 'report({failed => !!$@});', request=dict(request, address=address))
            self.assertTrue(json.loads(output)['failed'])

    # test_bootstrap(self) preserves credentials during prerequisite checks.
    def test_bootstrap(self):
        runtime = self.directory / 'perl'
        installed = self.directory / 'installed'
        received = self.directory / 'received'
        runtime.write_text('#!/bin/sh\nif [ "$1" = "-c" ]; then test -f ' +
                           shlex.quote(str(installed)) + '; exit $?; fi\n/bin/cat > ' +
                           shlex.quote(str(received)) + '\nprintf \'%s\\n\' \'{"stage":"complete"}\'\n')
        runtime.chmod(0o700)
        timeout = self.directory / 'timeout'
        timeout.write_text('#!/bin/sh\n[ "$1" = 900 ] || exit 99\nshift\nexec "$@"\n')
        timeout.chmod(0o700)
        cloud_init = self.directory / 'cloud-init'
        for code, installs, expected in [(0, True, 'complete'), (2, True, 'complete'),
                                         (0, False, 'perl'), (1, False, 'cloud_init_failed'),
                                         (124, False, 'cloud_init_timeout')]:
            for path in (installed, received):
                if path.exists():
                    # Each boot result starts without a runtime or accepted
                    # request.
                    path.unlink()
            cloud_init.write_text('#!/bin/sh\nif IFS= read -r private; then exit 99; fi\n' +
                                  (': > ' + shlex.quote(str(installed)) + '\n' if installs else '') +
                                  'exit ' + str(code) + '\n')
            cloud_init.chmod(0o700)
            command = self.invoke('print Cloudmin::SoftwareWorker::remote_command("root");').replace(
                '/usr/bin/perl', str(runtime))
            result = subprocess.run(['/bin/sh', '-c', command], input='private-key\n',
                                    env={'PATH': str(self.directory)}, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, universal_newlines=True, timeout=5)
            messages = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(messages[0], {'stage': 'boot'})
            self.assertEqual(messages[-1], {'stage': 'complete'} if expected == 'complete'
                             else {'stage': 'failed', 'reason': expected})
            self.assertNotIn('private-key', result.stdout + result.stderr)
            if installs:
                # Prerequisite checks must leave the private payload for the
                # helper.
                self.assertEqual(received.read_text(), 'private-key\n')
        command = self.invoke('print Cloudmin::SoftwareWorker::remote_command("root", 0);').replace(
            '/usr/bin/perl', str(runtime))
        result = subprocess.run(['/bin/sh', '-c', command], stdout=subprocess.PIPE,
                                universal_newlines=True, timeout=5)
        self.assertEqual(json.loads(result.stdout), {'stage': 'failed', 'reason': 'perl'})


# Python is only the test driver; every operation under test executes Perl.
if __name__ == '__main__':
    unittest.main()
