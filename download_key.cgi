#!/usr/local/bin/perl
# Output a binary key

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
($key) = grep { $_->{'id'} eq $in{'id'} } &list_ssh_keys();
$key || &error($text{'key_egone'});

print "Content-type: application/octet-stream\n\n";
print $key->{'keydata'};

