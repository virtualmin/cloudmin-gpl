#!/usr/local/bin/perl

use strict;
use warnings;
our (%in, %text, $remote_user);
require './server-manager-lib.pl';
ReadParse();

# Host administrators see presentation fields, never private job inputs.
my ($result, $error);
eval {
	require_access('host');
	my @ids = split(/,/, $in{'job'} || '');
	die "Select up to 100 image jobs\n" if (!@ids || @ids > 100);
	my $jobs = get_image_jobs();
	my @status = map { get_image_job_status($jobs->get($_)) } @ids;
	$result = $in{'batch'} ? { jobs => \@status } : $status[0];
	};
$error = "$@" if ($@);
print "Cache-Control: no-store\r\n";
print_json($error ? { error => $error } : $result, 0, 1);
