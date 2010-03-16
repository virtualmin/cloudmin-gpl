#!/usr/local/bin/perl
# Create or delete a disk resize schedule

require './server-manager-lib.pl';
&error_setup($text{'sdisk_err'});
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
$vhost = &get_parent_server($server);
&can_action_error($server, "disks");
use Time::Local;

# Get the disk
$lfunc = "type_".$server->{'manager'}."_list_disks";
$disks = &$lfunc($server, 0);
($disk) = grep { $_->{'real'} eq $in{'real'} } @$disks;
$disk || &error($text{'disk_egone'});

if ($in{'delete'}) {
	# Just remove any existing schedule
	&save_scheduled_change($server, "disk", $disk->{'real'});
	&webmin_log("unschedule", "disk", $server->{'host'},
		    { 'real' => $disk->{'real'} });
	}
else {
	# Validate and save
	$sched = { 'type' => 'disk',
		   'action' => 'disks' };
	$sched->{'real'} = $disk->{'real'};
	if ($access{'owner'}) {
		$sched->{'owner'} = $base_remote_user;
		}

	# Run time
	$in{'hour'} =~ /^\d+$/ && $in{'min'} =~ /^\d+$/ &&
	    $in{'day'} =~ /^\d+$/ && $in{'year'} =~ /^\d+$/ ||
                &error($text{'sdisk_edate'});
	eval { $time = timelocal(0, $in{'min'}, $in{'hour'},
                         $in{'day'}, $in{'month'}, $in{'year'}-1900) };
	$@ && &error($text{'sdisk_edate'});
	$time > time() ||
		&error($text{'sdisk_epast'});
	$sched->{'time'} = $time;

	# New size
	$in{'size'} =~ /^\d+$/ || &error($text{'disk_esize'});
	$incr = $in{'size'}*$in{'size_units'} - $disk->{'size'};
	$limits = &get_owner_limits();
	if ($limits && $limits->{'max_disk'} &&
	    $limits->{'disk'} + $incr > $limits->{'max_disk'}) {
		&error(&text('disk_elimit',
		       &nice_size($limits->{'max_disk'}),
		       &nice_size($limits->{'disk'})));
		}
	$hostfree = &host_free_disk($vhost, $server->{'manager'}, $server);
	if ($hostfree && $incr > $hostfree) {
		&error(&text('disk_ehostlimit', &nice_size($hostfree)));
		}
	$sched->{'size'} = $in{'size'}*$in{'size_units'};

	&save_scheduled_change($server, "disk", $disk->{'real'}, $sched);
	&webmin_log("schedule", "disk", $server->{'host'},
		    { 'real' => $disk->{'real'} });
	}
&redirect("list_disks.cgi?id=$server->{'id'}");

