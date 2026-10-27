#!/usr/bin/perl
# check-disk-labels.pl
# Renders installed VM and storage pages without changing guests or disks.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use Test::More;
my $root;
# Load the installed theme only on an authorized Linux
# host, never the workstation.
BEGIN {
	die "Run on an authorized Linux test host as root\n" unless $^O eq 'linux' && $< == 0;
	$root = abs_path("$Bin/../../..");
	$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
	$ENV{'WEBMIN_VAR'} = '/var/webmin';
	$ENV{'REMOTE_USER'} = 'root';
	# Render with the preferred test theme when installed; otherwise use the default.
	$ENV{'THEME_ROOT'} = "$root/authentic-theme" if (-d "$root/authentic-theme");
	chdir("$root/server-manager") or die $!;
	unshift(@INC, $root);
	$0 = "$root/server-manager/check-disk-labels.pl";
}
require './server-manager-lib.pl';
require './cloudmin-status-lib.pl';
require './cloudmin-storage-lib.pl';
require './cloudmin-storage-pages.pl';
$| = 1;
my $adapter = get_libvirt();
my $manager = get_vm_manager();
# Inventory existing guests without submitting any of the rendered forms.
foreach my $domain ($adapter->connect()->list_all_domains(0)) {
	# Transient guests and saved-memory guests have no editable settings page.
	next if (!$domain->is_persistent() || $domain->has_managed_save_image(0));
	my $id = $domain->get_uuid_string();
	my $before = $domain->get_xml_description(2);
	my $state = $domain->is_active();
	my $settings = $manager->settings($id);
	# Use the same saved settings for edit and deletion headings.
	my $editor = show_vm_edit_form($settings, 'display-only-token');
	my $details = show_vm_details($adapter->get_domain($id, 1));
	my $deletion = show_vm_edit_form($settings, 'display-only-token', 1);
	foreach my $disk (@{$settings->{'disks'}}) {
		my $label = html_escape(vm_disk_label($disk));
		my $target = $disk->{'target'};
		like($editor, qr/value=['"]disk:\Q$target\E['"][^>]*>\Q$label\E<\/option>/,
			'boot picker uses the friendly disk name');
		# The details view follows live attachments; configured-only disks may differ.
		like($details, qr/\Q$label\E/, 'details use the same disk name')
			if (!$state);
		like($deletion, qr/\Q$label\E/, 'deletion uses the same disk name')
			if ($disk->{'path'} || $disk->{'volume'});
		}
	# Rendering must neither rewrite the definition
	# nor change the power state.
	is($domain->get_xml_description(2), $before, 'rendering preserves the guest definition');
	is($domain->is_active(), $state, 'rendering preserves the guest power state');
	}
my $inventory = get_storage_service()->inventory();
# Volume labels are independent of whether a disk is attached to a guest.
my $storage = show_storage_volumes($inventory->{'pools'}, undef, $inventory->{'local'});
my $count = 0;
foreach my $pool (@{$inventory->{'pools'}}) {
	foreach my $volume (@{$pool->{'volumes'} || []}) {
		# Inactive or unreadable pools have no
		# rendered volume rows to check.
		next if (!$pool->{'active'} || $pool->{'volume_error'});
		my $label = html_escape(storage_volume_label($volume));
		like($storage, qr/\Q$label\E/, 'storage inventory renders its friendly volume label');
		$count++;
		}
	}
note("Checked $count storage volumes without changing them");
ok(defined($storage), 'installed theme renders the storage inventory');
done_testing();
