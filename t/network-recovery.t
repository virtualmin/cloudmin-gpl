use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use WebminCore;
our ($module_root_directory, $module_var_directory, $remote_user, %config,
     %text);
$module_root_directory = "$Bin/..";
$remote_user = 'fixture';
require "$module_root_directory/server-manager-lib-funcs.pl";
require "$module_root_directory/cloudmin-network-lib.pl";
require "$module_root_directory/cloudmin-pages.pl";
require "$module_root_directory/lib/Cloudmin/NetworkPreflight.pm";
$text{'check_network'} = 'Network $1';
$text{'check_network_restore'} = 'Restore Network Rules';
$text{'check_network_restore_desc'} = 'Restore rules';

{
	package RecoveryAdapter;

	# uri(self) selects local host checks without opening libvirt.
	sub uri
	{
	'qemu:///system'
	}

	# module_error(self) models available Perl bindings.
	sub module_error
	{
	undef
	}

	# probe(self) models a connected daemon.
	sub probe
	{
	{ ok => 1 }
	}

	# get_host_info(self) enables QEMU-specific readiness checks.
	sub get_host_info
	{
	{ driver => 'QEMU' }
	}

	# list_storage_pools(self) keeps unrelated storage readiness satisfied.
	sub list_storage_pools
	{
	[ { active => 1 } ]
	}
	package RecoveryTokens;

	# check_token(self, owner, token) rejects unsigned recovery requests.
	sub check_token
	{
	die "Bad token\n" if (($_[2] || '') ne 'signed');
	}
	package RecoveryJobs;

	# lock(self, resource, callback) runs the controller
	# without real lock files.
	sub lock
	{
	$_[2]->()
	}
	package RecoveryService;

	# assert_idle(self) models a job that prevents service restart.
	sub assert_idle
	{
	die "Jobs are running\n" if ($_[0]->{'busy'});
	}
	package main;
	}

# Both readiness and compact overview use the preflight's failed check.
{
	no warnings qw(redefine once);
	local *Cloudmin::NetworkPreflight::report = sub {
		return [ { id => 'net', name => 'default', ok => 0,
			   detail => 'Network default is missing IPv4 NAT rules',
			   repairable => 1 } ];
		};
	my $ready = check_host_readiness(bless({ }, 'RecoveryAdapter'));
	my ($network) =
		grep { $_->{'id'} eq 'network:net' } @{$ready->{'checks'}};
	ok($network && !$network->{'ok'} && $network->{'repairable'},
	   'readiness includes the failed network');
	ok(!$ready->{'ready'}, 'network failure makes host readiness fail');
	my $data = { readiness => $ready, token => 'signed' };
	my $form = show_network_recovery($data);
	like($form, qr/Restore Network Rules/, 'overview offers recovery');
	like($form, qr/method=['"]post['"]/i, 'recovery uses POST');
	like($form, qr/name="token"[^>]*value="signed"/,
	     'recovery form includes its token');
	like($form, qr/value="restore_network_rules"/,
	     'form targets the dedicated action');
	local *main::can_access = sub { $_[0] ne 'manage' };
	is(show_network_recovery($data), '',
	   'read-only viewers have no recovery control');
	}

# Controller permission, token, method and job checks precede service changes.
{
	no warnings qw(redefine once);
	my ($readonly, $denied, $restores) = ( 0, 0, 0 );
	my $service =
		bless({ adapter => bless({ }, 'RecoveryAdapter') },
		      'RecoveryService');
	local *main::is_readonly_mode = sub { $readonly };
	local *main::require_access = sub { die "Denied\n" if ($denied); };
	local *main::get_image_jobs = sub { bless({ }, 'RecoveryTokens') };
	local *main::get_vm_jobs = sub { bless({ }, 'RecoveryJobs') };
	local *main::get_network_service = sub { $service };
	local *main::webmin_log = sub { };
	local *Cloudmin::NetworkPreflight::restore =
		sub { $restores++; 'virtnetworkd.service' };
	local $ENV{'REQUEST_METHOD'} = 'POST';
	$readonly = 1;
	ok(!eval { change_network('restore_rules', { token => 'signed' }); 1 },
	   'read-only mutation rejected');
	$readonly = 0; $denied = 1;
	ok(!eval { change_network('restore_rules', { token => 'signed' }); 1 },
	   'missing permission rejected');
	$denied = 0;
	ok(!eval { change_network('restore_rules', { token => 'bad' }); 1 },
	   'invalid token rejected');
	$ENV{'REQUEST_METHOD'} = 'GET';
	ok(!eval { change_network('restore_rules', { token => 'signed' }); 1 },
	   'GET mutation rejected');
	$ENV{'REQUEST_METHOD'} = 'POST'; $service->{'busy'} = 1;
	ok(!eval { change_network('restore_rules', { token => 'signed' }); 1 },
	   'active jobs block restart');
	is($restores, 0, 'rejected requests never change the service');
	$service->{'busy'} = 0;
	is(change_network('restore_rules', { token => 'signed' }),
	   'virtnetworkd.service', 'authorized idle host can recover');
	is($restores, 1, 'one recovery operation issued');
	}
done_testing();
