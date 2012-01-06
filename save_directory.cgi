#!/usr/local/bin/perl
# Create, update or delete a disk image directory

require './server-manager-lib.pl';
&error_setup($text{'directory_err'});
&error_if_cloudmin_replica();
&can_action_error(undef, "global");
&ReadParse();
@directories = &list_directories();

if (!$in{'new'}) {	
	# Get the directory
	$directory = &get_directory($in{'id'});
	$directory || &error($text{'directory_egone'});
	}
else {
	$directory = { };
	}

if ($in{'delete'}) {
	# Delete this directory
	&error_setup($text{'directory_err2'});
	&delete_directory($directory);
	&webmin_log("delete", "directory", $directory->{'id'},
		    { 'dir' => $directory->{'dir'} });
	}
else {
	# Validate and store path and desc
	$in{'dir'} =~ /^\/\S+$/ || &error($text{'directory_edir'});
	$directory->{'dir'} = $in{'dir'};
	$in{'desc'} =~ /\S/ || &error($text{'directory_edesc'});
	$directory->{'desc'} = $in{'desc'};

	# Save allowed hosts
	if ($in{'hosts_def'}) {
		delete($directory->{'hosts'});
		}
	else {
		$directory->{'hosts'} = join(" ", split(/\r?\n/, $in{'hosts'}));
		$directory->{'hosts'} || &error($text{'directory_ehosts'});
		}

	# Save types
	if ($in{'managers_def'}) {
		delete($directory->{'managers'});
		}
	else {
		$directory->{'managers'} =
			join(" ", split(/\0/, $in{'managers'}));
		$directory->{'managers'} ||
			&error($text{'directory_emanagers'});
		}

	# Save plans
	if ($in{'plans_def'} == 2) {
		$directory->{'plans'} = 'none';
		}
	elsif ($in{'plans_def'} == 1) {
		delete($directory->{'plans'});
		}
	else {
		$directory->{'plans'} = join(" ", split(/\0/, $in{'plans'}));
		$directory->{'plans'} || &error($text{'directory_eplans'});
		}

	# Save and apply
	&save_directory($directory);
	&webmin_log($in{'new'} ? 'create' : 'modify', "directory",
		    $directory->{'id'},
		    { 'dir' => $directory->{'dir'} });
	}

&redirect("list_directories.cgi");

