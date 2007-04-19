#!/usr/local/bin/perl
# Refresh status of all managed servers

$main::no_acl_check++;
require './server-manager-lib.pl';

@servers = &list_managed_servers();
&parallel_check_server_status(\@servers);
