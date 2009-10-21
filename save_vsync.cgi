#!/usr/local/bin/perl
# Create, update or delete a replication config

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'vsync_err'});

if (!$in{'new'}) {
	$vsync = &get_virtualmin_sync($in{'id'});
        $vsync || &error($text{'vsync_egone'});
	}

if ($in{'delete'}) {
	# Just remove this replication config
	$src = &get_managed_server($vsync->{'src'});
	&delete_virtualmin_sync($vsync);
	&webmin_log("delete", "vsync", $src->{'host'});
	}
else {
	# Validate inputs, starting with source host
	$src = &get_managed_server($in{'src'});
	$src && &can_action("domains", $src) ||
		&error($text{'vsync_esrc'});
	$vsync->{'src'} = $src->{'id'};

	# Parse destinations
	@destids = split(/\r?\n/, $in{'dest'});
	@destids || &error($text{'vsync_edests'});
	foreach $id (@destids) {
		$dest = &get_managed_server($id);
		$dest && &can_action("domains", $dest) ||
			&error($text{'vsync_edest'});
		}
	$vsync->{'dest'} = join(" ", @destids);

	# Parse domains
	# XXX

	# Parse global settings
	# XXX
	
	# Parse features
	# XXX

	# Parse schedule
	# XXX

	# Parse email
	# XXX

	# Update or create sync

	&webmin_log($in{'new'} ? "create" : "modify", "vsync", $src->{'host'});
	}

