#!/usr/bin/perl
# Render both resource views without initializing Webmin or contacting libvirt.
use strict;
use warnings;
use FindBin qw($Bin);
# Support installed Webmin on test VMs as well as a sibling
# development checkout.
use lib ($ENV{'WEBMIN_ROOT'} || "$Bin/../../webmin");
use WebminCore;
our (%config, %text, $root_directory, $module_root_directory);
$root_directory = $ENV{'WEBMIN_ROOT'} || "$Bin/../../webmin";
$module_root_directory = "$Bin/..";
for my $file ( "$root_directory/lang/en", "$module_root_directory/lang/en" ) {
	open(my $fh, '<', $file) or die $!;
	while (<$fh>) { chomp; $text{$1} = $2 if (/^([^=]+)=(.*)$/); }
	}
# init_config normally supplies core translations to Webmin's size formatter.
%WebminCore::text = %text;
require "$module_root_directory/cloudmin-pages.pl";
require "$module_root_directory/cloudmin-status-lib.pl";
no warnings 'redefine';
*main::is_readonly_mode = sub { 0 };
my $vm = { uuid => '11111111-2222-3333-4444-555555555555',
	   name => 'resource-fixture',
	   description => '<img src=x onerror="window.injected=true">',
	   state => 'running', active => 1,
	   persistent => 1, autostart => 1, vcpus => 2, memory_kib => 1048576,
	   max_memory_kib => 2097152,
	   architecture => 'aarch64', machine => 'virt', firmware => 'efi',
	   cpu_mode => 'host-passthrough',
	   graphics => { type => 'vnc', passwd => 'must-not-be-rendered' },
	   interfaces => [ { mac => '52:54:00:00:00:01', type => 'network',
			     source => '<default>', model => 'virtio', target =>
									       'vnet1' } ],
	   disks => [ { target => 'vda', device => 'disk',
			path => '/images/<guest>.qcow2', format => 'qcow2',
			bus => 'virtio' } ],
	   macs => [ '52:54:00:00:00:01' ],
	   addresses => [ { address => '192.0.2.1',
			    source => 'agent' } ] };
my $dashboard = {
	ready => 1, host => { hostname => 'fixture.test' },
	readiness => { checks => [ ] }, counts => { hosts => 1,
						    vms => 1,
						    running => 1,
						    jobs => 0 },
	servers => [ $vm ], token => 'fixture-token', live => 1,
	status_config => get_overview_status_config('fixture-token') };
my $overview = show_dashboard_page($dashboard);
my $empty = show_dashboard_page({ %$dashboard, servers => [ ],
				  counts => { hosts => 1, vms => 0,
					      running => 0,
					      jobs => 0 } });
my $details = show_vm_details($vm);
# Compact variants use the same live templates as the configured dashboard.
my %compact;
foreach my $columns ( 'name,state', 'name,state,os,memory,autostart,controls',
		      'name,state,ips,macs' ) {
	local $config{'machine_columns'} = $columns;
	$compact{$columns} = show_dashboard_page({ %$dashboard,
						   status_config =>
							   get_overview_status_config('fixture-token') });
	}
print WebminCore::convert_to_json({ %compact, overview => $overview, empty => $empty,
			      details => $details,
			      terminal => show_status_summary($vm) }, 0, 1);
