#!/usr/local/bin/perl
# Refresh status of all managed servers

package server_manager;
$main::no_acl_check++;
require './server-manager-lib.pl';
$override_webmin_script_type = 'status';

# For a replica, only update self
if (&is_cloudmin_replica()) {
	$this = &get_managed_server(0);
	@servers = $this ? ( $this ) : ( );
	}
else {
	@servers = &list_managed_servers();
	}

if (@ARGV) {
	# Limit to specified hostnames
	%hosts = map { $_, 1 } @ARGV;
	@servers = grep { $hosts{$_->{'host'}} } @servers;
	}

# Exclude servers whose status only gets updated manually
@servers = grep { !$_->{'manual_status'} } @servers;

# Identify parent and virtual systems
@pservers = grep { !&is_virtual_server($_) } @servers;
@oservers = grep { &is_virtual_server($_) } @servers;

foreach $l (\@pservers, \@oservers) {
	&parallel_check_server_status($l, 0, 1);
	}

# Once systems have been updated, re-check alerts based on new history
if (!&is_cloudmin_replica()) {
	&evaluate_all_alerts(\@servers);
	}

# Also update any DNS load balancers
if (!&is_cloudmin_replica()) {
	&evaluate_all_roundrobins(\@servers);
	}

# Run any scheduled changes
if (!&is_cloudmin_replica() && defined(&run_scheduled_changes)) {
	$done = &run_scheduled_changes(\@servers);
	if ($done) {
		&cloudmin_api_log([])
		}
	}

# Perform failovers based on new status
if (!&is_cloudmin_replica() && defined(&check_for_failovers)) {
	&check_for_failovers(\@servers);
	}

# Evaluate auto-scaling groups
if (defined(&evaluate_all_scalegroups)) {
	&evaluate_all_scalegroups();
	}

# Check Virtualmin licences for the account, to prevent delays in the UI
@proimages = grep { $_->{'virtualmin'} eq 'pro' } &list_server_images();
if (@proimages && !&test_lock($virtualmin_licences_file)) {
	&list_virtualmin_licences();
	}

if (&get_replication_mode() == 2) {
	# Replicate changes if enabled
	if (@ARGV) {
		foreach $s (grep { $_->{'id'} ne '0' } @servers) {
			&replicate_host_to_all_servers($s, 0);
			}
		}
	else {
		&replicate_to_servers(0);
		}
	}
