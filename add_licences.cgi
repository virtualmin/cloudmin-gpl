#!/usr/local/bin/perl
# Bulk-adds a bunch of licences

require './server-manager-lib.pl';
&error_setup($text{'ladd_err'});
&ReadParse();

# Create the licence objects
if (defined($in{'licences'})) {
	# Bulk add
	foreach $line (split(/\r?\n/, $in{'licences'})) {
		next if ($line !~ /\S/);
		$line =~ s/^\s+//;
		$line =~ s/\s+$//;
		($serial, $key) = split(/\s+/, $line);
		$serial && $key || &error(&text('ladd_eline', $line));
		push(@newlics, { 'serial' => $serial,
				 'key' => $key });
		}
	@newlics || &error($text{'ladd_enone'});
	}
else {
	# Adding one
	$in{'serial'} =~ /^\S+$/ || $text{'ladd_eserial'};
	$in{'key'} =~ /^\S+$/ || $text{'ladd_ekey'};
	push(@newlics, { 'serial' => $in{'serial'},
			 'key' => $in{'key'} });
	}

# Validate them, by checking for clashes or bogus IDs
@lics = &list_virtualmin_licences();
foreach $nl (@newlics) {
	($clash) = grep { $_->{'serial'} eq $nl->{'serial'} } @lics;
	$clash && &error(&text('ladd_eclash', $nl->{'serial'}));
	$done{$nl->{'serial'}}++ && &error(&text('ladd_edup', $nl->{'serial'}));
	$ok = &check_virtualmin_serial($nl->{'serial'}, $nl->{'key'});
	$ok == 1 || &error(&text('ladd_echeck', $nl->{'serial'}, $nl->{'key'}));
	}

# Save then
push(@lics, @newlics);
&save_virtualmin_licences(\@lics);

&redirect("list_licences.cgi");
