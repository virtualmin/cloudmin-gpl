#!/usr/local/bin/perl
# Create, update or delete a replication config

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'vsync_err'});
&error_if_cloudmin_replica();
&can_action_error(undef, "domains");

if (!$in{'new'}) {
	$vsync = &get_virtualmin_sync($in{'id'});
        $vsync || &error($text{'vsync_egone'});
	&can_virtualmin_sync($vsync) || &error($text{'vsync_ecannot'});
	}

if ($in{'delete'}) {
	# Just remove this replication config
	$src = &get_managed_server($vsync->{'src'});
	@doms = split(/\s+/, $vsync->{'doms'});
	&delete_virtualmin_sync($vsync);
	&webmin_log("delete", "vsync", $src->{'host'},
		    { 'doms' => \@doms });
	}
elsif ($in{'run'}) {
	# Redirec to execute page
	&redirect("exec_vsync.cgi?id=$in{'id'}");
	return;
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
		$dest->{'id'} eq $src->{'id'} &&
			&error(&text('vsync_edestsame', $dest->{'host'}));
		}
	$vsync->{'dest'} = join(" ", @destids);

	# Parse domains
	@doms = split(/\r?\n/, $in{'doms'});
	$vsync->{'doms'} = join(" ", @doms);
	%srcdoms = map { $_->{'dom'}, $_ } &get_server_domains($src);
	foreach $dname (@doms) {
		$srcdoms{$dname} ||
		    &error(&text('vsync_edomon', &show_domain_name($dname)));
		}

	# Parse global settings
	$vsync->{'tmpls'} = join(" ", split(/\0/, $in{'tmpl'}));
	$vsync->{'doms'} || $vsync->{'tmpls'} || &error($text{'vsync_edoms'});
	
	# Parse features
	if ($in{'feats_def'}) {
		delete($vsync->{'feats'});
		}
	else {
		@feats = split(/\0/, $in{'feats'});
		@feats || &error($text{'vsync_efeats'});
		$vsync->{'feats'} = join(" ", @feats);
		}

	# Parse schedule
	$vsync->{'enabled'} = $in{'enabled'};
	&virtualmin_ui_parse_cron_time("when", $vsync, \%in);

	# Parse email
	if ($in{'emailother'}) {
		$in{'email'} =~ /^\S+\@\S+$/ ||
			&error($text{'vsync_eemail'});
		$vsync->{'email'} = $in{'email'};
		}
	else {
		delete($vsync->{'email'});
		}
	if (!$access{'owner'}) {
		$vsync->{'emailmaster'} = $in{'emailmaster'};
		}

	# Update or create sync
	&save_virtualmin_sync($vsync);

	&webmin_log($in{'new'} ? "create" : "modify", "vsync", $src->{'host'},
		    { 'doms' => \@doms });
	}
&redirect("list_vsyncs.cgi");

