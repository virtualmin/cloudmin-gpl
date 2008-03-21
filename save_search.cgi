#!/usr/local/bin/perl
# Update the default search file with current settings

require './server-manager-lib.pl';
&ReadParse();
if ($in{'in'}) {
	$ENV{'QUERY_STRING'} = $in{'in'};
	delete($in{'in'});
	&ReadParse(undef, 'GET');
	&write_file($default_search_file, \%in);
	}
else {
	&unlink_file($default_search_file);
	}
&redirect("");

