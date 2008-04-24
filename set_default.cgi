#!/usr/local/bin/perl
# Change the default host system of some type

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
@servers = &list_managed_servers();

# Clear old default
foreach $s (@servers) {
	if ($s->{$in{'type'}.'_default'}) {
		delete($s->{$in{'type'}.'_default'});
		&save_managed_server($s);
		}
	}

# Set new one
if ($in{'default'} ne '') {
	($s) = grep { $_->{'id'} eq $in{'default'} } @servers;
	$s->{$in{'type'}.'_default'} = 1;
	&save_managed_server($s);
	}

&redirect($ENV{'HTTP_REFERER'});

