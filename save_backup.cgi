#!/usr/local/bin/perl
# Create, update or delete a backup

require './server-manager-lib.pl';
&error_setup($text{'backup_err'});
&error_if_cloudmin_replica();
&can_action_error(undef, "backup");
&ReadParse();
if (!$in{'new'}) {
	($backup) = grep { $_->{'id'} eq $in{'id'} } &list_available_backups();
	$backup || &error($text{'backup_egone'});
	}
else {
	# Create new empty object
	$backup = { };
	if ($access{'owner'}) {
		$backup->{'owner'} = $base_remote_user;
		}
	}

if ($in{'delete'}) {
	# Just remove this backup
	&delete_backup($backup);
	&webmin_log("delete", "backup", $backup->{'id'},
		    { 'dest' => $backup->{'dest'} });
	}
elsif ($in{'restore'}) {
	# Redirect to restore form
	&redirect("restore_form.cgi?id=$backup->{'id'}");
	return;
	}
elsif ($in{'run'}) {
	# Redirect to run backup
	&redirect("backup.cgi?id=$backup->{'id'}");
	return;
	}
elsif ($in{'logs'}) {
	# Redirect to logs for this backup
	&redirect("list_backuplogs.cgi?log=$backup->{'id'}");
	return;
	}
else {
	# Validate and store inputs
	@canservers = grep { &supports_backup($_) }
                &list_available_managed_servers_sorted();
	@canvhosts = &list_parent_servers(\@canservers);
	if (defined(&list_vhost_locations)) {
		@canlocs = &list_vhost_locations(\@canvhosts);
		}
	foreach $f ('servers', 'groups', 'owners', 'managers',
		    'vhosts', 'locs') {
		delete($backup->{$f});
		}
	if ($in{'mode'} == 0) {
		# All systems
		$backup->{'servers'} = '*';
		}
	elsif ($in{'mode'} == 1) {
		# Selected systems
		%sids = map { $_, 1 } split(/\r?\n/,$in{'servers'});
		@servers = grep { $sids{$_->{'id'}} } @canservers;
		@servers || &error($text{'backup_eservers'});
		$backup->{'servers'} = join(' ', map { $_->{'id'} } @servers);
		}
	elsif ($in{'mode'} == 2) {
		# Selected groups
		$backup->{'groups'} = join(" ", split(/\r?\n/, $in{'groups'}));
		$backup->{'groups'} || &error($text{'alert_egroups'});
		}
	elsif ($in{'mode'} == 3) {
		# Selected owners
		$backup->{'owners'} = join(" ", split(/\r?\n/, $in{'owners'}));
		$backup->{'owners'} || &error($text{'alert_eowners'});
		}
	elsif ($in{'mode'} == 4) {
		# Checked system types
		$backup->{'managers'} = join(" ", split(/\0/, $in{'managers'}));
		$backup->{'managers'} || &error($text{'alert_emanagers'});
		}
	elsif ($in{'mode'} == 7) {
		# Selected host systems
		%vids = map { $_, 1 } split(/\r?\n/, $in{'vhosts'});
		@vhosts = grep { $vids{$_->{'id'}} } @canvhosts;
		@vhosts || &error($text{'alert_evhosts'});
		$backup->{'vhosts'} = join(' ', map { $_->{'id'} } @vhosts);
		}
	elsif ($in{'mode'} == 8) {
		# Selected location groups
		%lids = map { $_, 1 } split(/\r?\n/, $in{'locs'});
		@locs = grep { $lids{$_->{'id'}} } @canlocs;
		@locs || &error($text{'alert_elocs'});
		$backup->{'locs'} = join(' ', map { $_->{'id'} } @locs);
		}
	$backup->{'shutdown'} = $in{'shutdown'};
	$backup->{'parallel'} = $in{'parallel'};

	# Parse destination
	if ($in{'dest_mode'} == -1) {
		# Use host system setting
		delete($backup->{'dest'});
		}
	elsif ($in{'dest_mode'} == 2) {
		# Some other system
		$dest = { 'mode' => 2 };
		$dest->{'path'} = $in{'vm2dir'};
		$dest->{'id'} = $in{'vm2'};
		$dest->{'path'} =~ /^\/\S+/ || &error($text{'backups_emode2'});
		$backup->{'dest'} = &join_backup_destination($dest);
		}
	elsif ($in{'dest_mode'} == 3 || $in{'dest_mode'} == 4) {
		# SSH or FTP
		$dest = { 'mode' => $in{'dest_mode'} };
		$pfx = $in{'dest_mode'} == 3 ? 'ssh' : 'ftp';
		$err = &parse_backup_ssh_dest($dest, $pfx, \%in);
		&error($err) if ($err);
		$backup->{'dest'} = &join_backup_destination($dest);
		}
	elsif ($in{'dest_mode'} == 5) {
		# Amazon S3
		$dest = { 'mode' => 5 };
		$err = &parse_backup_s3_dest($dest, \%in);
		&error($err) if ($err);
		$backup->{'dest'} = &join_backup_destination($dest);
		}
	elsif ($in{'dest_mode'} == 6) {
		# Rackspace Cloud files
		$dest = { 'mode' => 6 };
		$err = &parse_backup_rs_dest($dest, \%in);
		&error($err) if ($err);
		$backup->{'dest'} = &join_backup_destination($dest);
		}

	# Parse schedule
	$backup->{'enabled'} = $in{'enabled'};
	&virtualmin_ui_parse_cron_time("when", $backup, \%in);

	# Parse email settings
	if ($in{'emailother'}) {
		$in{'email'} =~ /^\S+\@\S+$/ ||
			&error($text{'backup_eemail'});
		$backup->{'email'} = $in{'email'};
		}
	else {
		delete($backup->{'email'});
		}
	if (!$access{'owner'}) {
		$backup->{'emailmaster'} = $in{'emailmaster'};
		}
	$backup->{'always'} = $in{'always'};
	if ($in{'purge_def'}) {
		delete($backup->{'purge'});
		}
	else {
		($base, $date) = &extract_purge_path($backup->{'dest'});
		$base || $date || &error($text{'backup_epurgedate'});
		$in{'purge'} =~ /^[0-9\.]+$/ && $in{'purge'} > 0 ||
			&error($text{'backup_epurge'});
		$backup->{'purge'} = $in{'purge'};
		}

	# Save pre and post commands
	$master = &get_managed_server(0);
	if (&can_action($master, "run")) {
		$backup->{'pre'} = $in{'pre'};
		$backup->{'pre_host'} = $in{'pre_host'};
		$backup->{'post'} = $in{'post'};
		$backup->{'post_host'} = $in{'post_host'};
		}
	
	# Update the backup
	&save_backup($backup);
	&webmin_log($in{'new'} ? "create" : "modify", "backup", $backup->{'id'},
		    { 'dest' => $backup->{'dest'} });
	}

&redirect("list_backups.cgi");

