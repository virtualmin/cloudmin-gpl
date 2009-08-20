#!/usr/local/bin/perl
# Create, update or delete a backup

require './server-manager-lib.pl';
&error_setup($text{'backup_err'});
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
else {
	# Validate and store inputs
	@allservers = grep { &supports_backup($_) }
                &list_available_managed_servers_sorted();
	if ($in{'servers_def'}) {
		$backup->{'servers'} = '*';
		}
	else {
		%sids = map { $_, 1 } split(/\0/, $in{'servers'});
		@servers = grep { $sids{$_->{'id'}} } @allservers;
		@servers || &error($text{'backup_eservers'});
		$backup->{'servers'} = join(' ', map { $_->{'id'} } @servers);
		}
	
	$backup->{'shutdown'} = $in{'shutdown'};
	$backup->{'parallel'} = $in{'parallel'};

	# Parse destination
	if ($in{'dest_mode'} == -1) {
		# Use host system setting
		delete($backup->{'dest'});
		}
	else {
		# SSH or FTP
		$dest = { 'mode' => $in{'dest_mode'} };
		$pfx = $in{'dest_mode'} == 3 ? 'ssh' : 'ftp';
		$err = &parse_backup_ssh_dest($dest, $pfx, \%in);
		&error($err) if ($err);
		$backup->{'dest'} = &join_backup_destination($dest);
		}

	# Parse schedule
	$backup->{'enabled'} = $in{'enabled'};
	&virtualmin_ui_parse_cron_time("when", $backup, \%in);

	# Parse email settings
	if ($in{'email_def'}) {
		delete($backup->{'email'});
		}
	else {
		$in{'email'} =~ /^\S+\@\S+$/ ||
			&error($text{'backup_eemail'});
		$backup->{'email'} = $in{'email'};
		}
	$backup->{'always'} = $in{'always'};
	
	# Update the backup
	&save_backup($backup);
	}

&redirect("list_backups.cgi");

