#!/usr/local/bin/perl
# Refresh status of all managed servers

$main::no_acl_check++;
require './server-manager-lib.pl';

@servers = &list_managed_servers();
if (@ARGV) {
	# Limit to specified hostnames
	%hosts = map { $_, 1 } @ARGV;
	@servers = grep { $hosts{$_->{'host'}} } @servers;
	}
&parallel_check_server_status(\@servers);
