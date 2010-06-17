#!/usr/local/bin/perl
# Refresh status of all managed servers

package server_manager;
$main::no_acl_check++;
require './server-manager-lib.pl';

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
&parallel_check_server_status(\@servers, 0, 1);

# Once systems have been updated, re-check alerts based on new history
if (!&is_cloudmin_replica()) {
	&evaluate_all_alerts(\@servers);
	}

# Run any scheduled changes
if (!&is_cloudmin_replica()) {
	$done = &run_scheduled_changes(\@servers);
	if ($done) {
		&cloudmin_api_log([])
		}
	}

# Perform failovers based on new status
if (!&is_cloudmin_replica() && defined(&check_for_failovers)) {
	&check_for_failovers(\@servers);
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
