#!/usr/local/bin/perl
# Switch the login to a system owner

require './server-manager-lib.pl';
&ReadParse();
&can_action_error(undef, "global");
&foreign_require("acl", "acl-lib.pl");

# Get the owner
$owner = &get_system_owner($in{'name'});
$owner || &error($text{'owner_egone'});

# Hack the Webmin session DB
&get_miniserv_config(\%miniserv);
&acl::open_session_db(\%miniserv);
$skey = defined(&acl::session_db_key) ? &acl::session_db_key($main::session_id)
				      : $main::session_id;
($olduser, $oldtime) = split(/\s+/, $acl::sessiondb{$skey});
$olduser || &error($acl::text{'switch_eold'});
$acl::sessiondb{$skey} = "$owner->{'name'} $oldtime $ENV{'REMOTE_ADDR'}";
dbmclose(%acl::sessiondb);
&reload_miniserv();
&redirect("/");

