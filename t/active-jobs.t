use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;

# Load the collector with isolated stores and no host or libvirt access.
our ($module_root_directory, $remote_user, %text);
$module_root_directory = "$Bin/..";
$remote_user = 'fixture-owner';

# is_readonly_mode() models an administrator allowed to control host jobs.

sub is_readonly_mode
{
0
}

# text(key, [values...]) - Exposes message keys and values for assertions.

sub text
{
return join(': ', @_);
}
require "$module_root_directory/server-manager-lib-funcs.pl";

{
	package JobStore;

	# list(self, [owner], [active]) Records filters and
	# supplies isolated records.

	sub list
	{
	my ($self, @args) = @_;
	$self->{'args'} = \@args;
	die $self->{'error'} if ($self->{'error'});
	return $self->{'records'};
	}

	# list_pending(self, owner) includes retained failures
	# in the same fixture.

	sub list_pending
	{
	return $_[0]->list($_[1], 1);
	}
	package Host;

	# uri(self) - Provides a display-only connection identifier.

	sub uri
	{
	return 'test:///fixture';
	}

	# list_domains(self) - Supplies an empty inventory without libvirt.

	sub list_domains
	{
	return [ ];
	}
	}

my $images = bless({ records => [ ] }, 'JobStore');
my $creations = bless({ records => [ ] }, 'JobStore');
my $image = { id => 'a' x 32, name => 'Import', state => 'downloading',
	      created => 20, bytes => 256, total => 1024, transferred => 128,
	      token => 'private-token', source_path => '/private/input' };
my $creation = { id => 'b' x 32, state => 'running', phase => 'disk',
		 created => 30, cleanup_warning => 'cleanup detail',
		 audit_warning =>
			 'audit detail',
		 request => { name => 'Guest', start => 1,
			      password_hash => 'private-hash',
			      ssh_keys => 'private-input' } };

{
	no warnings qw(redefine once);
	local *main::get_image_jobs = sub { return $images; };
	local *main::get_vm_jobs = sub { return $creations; };
	local *main::get_libvirt = sub {
		ok($_[0],
		   'overview connection permits guest-agent address queries');
		return bless({ }, 'Host');
		};
	local *main::check_host_readiness = sub {
		return { ready => 1, probe => { ok => 1 }, checks => [ ] };
		};
	# Zero, image-only, creation-only and mixed work share
	# one count and listing.
	foreach my $pair ( [ [ ], [ ] ], [ [ $image ], [ ] ], [ [ ],
								[ $creation ] ],
			   [ [ $image ], [ $creation ] ] ) {
		($images->{'records'},
		 $creations->{'records'}) = @$pair;
		my $data = get_active_jobs();
		is(scalar(@{$data->{'jobs'}}),
		   @{$pair->[0]} + @{$pair->[1]},
		   'all active job types are included');
		is(get_dashboard()->{'counts'}->{'jobs'},
		   scalar(@{$data->{'jobs'}}),
		   'overview count matches its destination');
		}
	is_deeply($images->{'args'}, [ undef, 1 ],
		  'image visibility matches Image Manager');
	is_deeply($creations->{'args'}, [ undef, 1 ],
		  "host administrators see every owner's unfinished jobs");
	my $data = get_active_jobs();
	is_deeply([ map { $_->{'id'} } @{$data->{'jobs'}} ], [ 'b' x 32,
							       'a' x 32 ],
		  'mixed jobs are newest first');
	is($data->{'jobs'}->[0]->{'name'}, 'Guest',
	   'creation name is extracted for display');
	ok(!exists($data->{'jobs'}->[0]->{'request'}),
	   'provisioning inputs are not passed to the page');
	is_deeply([ @{$data->{'jobs'}->[0]}{qw(cleanup_warning audit_warning)} ],
		  [ 'cleanup detail', 'audit detail' ],
		  'recovery diagnostics reach the shared job view');
	ok(!exists($data->{'jobs'}->[1]->{'token'}),
	   'image tokens are not passed to the page');
	is_deeply([ @{$data->{'jobs'}->[1]}{qw(bytes total transferred)} ],
		  [ 256, 1024, 128 ],
		  'public status carries measured transfer progress');

	# A failed store leaves the other job type visible
	# with an explicit error.
	foreach my $store ( $images, $creations ) {
		$store->{'error'} = "fixture unavailable\n";
		$data = get_active_jobs();
		is(scalar(@{$data->{'jobs'}}), 1,
		   'healthy store remains visible');
		like($data->{'errors'}->[0], qr/fixture unavailable/,
		     'failed store is reported');
		delete($store->{'error'});
		}
	}

# A token-store failure must leave the overview readable without power controls.
{
	no warnings qw(redefine once);
	local $INC{'./server-manager-lib.pl'} = 1;
	local $INC{'./cloudmin-status-lib.pl'} = 1;
	local *main::error_setup = sub { };
	local *main::ReadParse = sub { };
	my @header;
	local *main::ui_print_header = sub { @header = @_; };
	local *main::ui_print_footer = sub { };
	local *main::ui_page_assets = sub { '' };
	local *main::is_readonly_mode = sub { 0 };
	local *main::cloudmin_license_status =
		sub { { allowed => 1, state => 'gpl' } };
	local *main::get_overview_status_config = sub { '{}' };
	local *main::show_status_script = sub { '' };
	local *main::print_vm_change_result = sub { };
	local *main::html_escape = sub { $_[0] };
	local *main::recover_vm_jobs = sub { die "Store unavailable\n"; };
	local *main::get_image_jobs = sub { die "Store unavailable\n"; };
	my $inventory = { host => { },
			  servers => [ { name => 'Existing guest' } ] };
	local *main::get_dashboard = sub { $inventory };
	local *main::show_dashboard_page = sub {
		is($_[0]->{'servers'}->[0]->{'name'}, 'Existing guest',
		   'overview retains the guest inventory when the token store fails');
		ok(!$_[0]->{'token'},
		   'failed token lookup leaves power controls disabled');
		is($_[0]->{'status_config'}, '{}',
		   'page builder receives the live configuration');
		return '';
		};
	do "$Bin/../index.cgi";
	is($@, '', 'overview survives unavailable job stores');
	ok(!defined($header[0]), 'missing libvirt version omits the subtitle');

	# Keep the original overview subtext argument and header layout.
	$inventory->{'host'}->{'libvirt_version'} = '11.10.0';
	do "$Bin/../index.cgi";
	is($@, '', 'overview renders with a known libvirt version');
	is($header[0], 'index_subtitle: 11.10.0',
	   'libvirt version replaces the original overview subtext');
	is(scalar(@header), 6, 'header retains its original arguments');
	}
done_testing();
