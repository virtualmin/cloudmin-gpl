#!/usr/local/bin/perl
# Change the default host system of some type

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
@servers = &list_managed_servers();
$tfunc = "type_".$in{'type'}."_desc";

# Clear old default
foreach $s (@servers) {
	if ($s->{$in{'type'}.'_default'}) {
		delete($s->{$in{'type'}.'_default'});
		&obtain_lock_server($s);
		&save_managed_server($s);
		&release_lock_server($s);
		$olddef = $s;
		}
	}

# Set new one
if ($in{'default'} ne '') {
	($s) = grep { $_->{'id'} eq $in{'default'} } @servers;
	$s->{$in{'type'}.'_default'} = 1;
	&obtain_lock_server($s);
	&save_managed_server($s);
	&release_lock_server($s);
	&webmin_log("default", "server", $s->{'host'},
		    { 'type' => ucfirst($in{'type'}) });
	}
elsif ($olddef) {
	&webmin_log("undefault", "server", $olddef->{'host'},
		    { 'type' => $in{'type'} });
	}

&redirect($ENV{'HTTP_REFERER'});

