#!/usr/local/bin/perl
# Check licence validity, and save the status

$main::no_acl_check++;
require './server-manager-lib.pl';

&read_file($licence_status, \%licence);
&update_server_manager_licence(\%licence);
&write_file($licence_status, \%licence);
