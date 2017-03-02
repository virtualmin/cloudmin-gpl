#!/usr/local/bin/perl
# Actually restore a system or systems

require './server-manager-lib.pl';
&can_action_error(undef, "backup");
&ReadParse();
&error_setup($text{'rrun_err'});
%want = map { $_, 1 } split(/\0/, $in{'servers'});

if ($in{'log'}) {
	# From backup log, for one system
	$backuplog = &get_backup_log($in{'log'});
	$backuplog || &error($text{'restore_egone'});
	$server = &get_managed_server($backuplog->{'server'}) ||
		  &get_managed_server_by("host", $backuplog->{'host'});
	if ($server) {
		# Restoring existing system
		@servers = ( $server );
		}
	elsif ($backuplog->{'host'}) {
		# Restoring a specific hostname that doesn't exist anymore
		$server = &get_missing_backup_server($backuplog->{'host'},
						     $backuplog->{'base_dest'});
		$server || &error($text{'restore_egone3'});
		@missing = ( $server );
		}
	else {
		&error($text{'restore_egone4'});
		}
	$backup = { 'servers' => join(' ', map { $_->{'id'} } @servers),
		    'missing' => join(' ', map { $_->{'host'} } @missing),
		    'dest' => $backuplog->{'dest'},
		    'owner' => $backuplog->{'owner'},
		    'parallel' => 0 };
	$backup->{'dest'} =~ s/\/([^\/]+)$//;	# Remove host.tar.gz
	}
elsif ($in{'id'}) {
	# Some or all systems from a backup schedule
	($backup) = grep { $_->{'id'} eq $in{'id'} } &list_backups();
	$backup || &error($text{'restore_egone2'});
	!$access{'owner'} || $backup->{'owner'} eq $base_remote_user ||
		&error($text{'restore_ecannot'});
	@servers = grep { $want{$_->{'id'}} } &get_backup_servers($backup);
	$backup->{'parallel'} = $in{'parallel'};
	$backup->{'servers'} = join(' ', map { $_->{'id'} } @servers);
	}
else {
	# Parse backup source fields
	if ($in{'dest_mode'} == 3 || $in{'dest_mode'} == 4) {
		# SSH or FTP server
		$dest = { 'mode' => $in{'dest_mode'} };
		$pfx = $in{'dest_mode'} == 3 ? 'ssh' : 'ftp';
		$err = &parse_backup_ssh_dest($dest, $pfx, \%in);
		&error($err) if ($err);
		}
	elsif ($in{'dest_mode'} == 5) {
		# S3 bucket
		$dest = { 'mode' => 5 };
		$err = &parse_backup_s3_dest($dest, \%in);
                &error($err) if ($err);
		}
	elsif ($in{'dest_mode'} == 2) {
		# Some other system
		$dest = { 'mode' => 2 };
		$dest->{'path'} = $in{'vm2dir'};
		$dest->{'id'} = $in{'vm2'};
		$dest->{'path'} =~ /^\/\S+/ || &error($text{'backups_emode2'});
		}
	$deststr = $dest ? &join_backup_destination($dest) : undef;

	# Allow free choice of systems and source (Host, FTP or SSH)
	@allservers = grep { &supports_backup($_) }
			&list_available_managed_servers_sorted();
	if ($in{'servers_mode'} == 0) {
		# From selected systems
		@servers = grep { $want{$_->{'id'}} } @allservers;
		@servers || &error($text{'restore_enone'});
		}
	else {
		# A specific hostname
		$in{'hostname'} =~ /^[a-z0-9\.\_\-]+$/i ||
			&error($text{'restore_ehostname'});
		($missing) = grep { $_->{'name'} eq $in{'hostname'} }
				  @allservers;
		if ($missing) {
			# Actually exists
			@servers = ( $missing );
			}
		else {
			# May or may not exist at the backup dest
			$missing = &get_missing_backup_server(
					$in{'hostname'}, $deststr);
			$missing || &error(&text('restore_ehostname2',
						 $in{'hostname'}));
			@missing = ( $missing );
			}
		}
	$backup = { 'servers' => join(' ', map { $_->{'id'} } @servers),
		    'missing' => join(' ', map { $_->{'host'} } @missing),
		    'dest' => $deststr,
		    'parallel' => $in{'parallel'} };
	}

# Parse host system
if ($in{'vhost'} ne '') {
	($vhost) = grep { $_->{'id'} eq $in{'vhost'} }
			&list_all_available_host_servers();
	$vhost || &error($text{'restore_evhost'});
	$backup->{'newvhost'} = $vhost->{'id'};
	}

# Double-check access to servers
foreach $s (@servers) {
	&can_action_error($s, "backup");
	}

&ui_print_unbuffered_header(undef, $text{'restore_title'}, "");

# Ask for confirmation first if needed
if (!$in{'confirm'}) {
	my @hiddens;
	foreach my $k (keys %in) {
		push(@hiddens, map { [ $k, $_ ] } split(/\0/, $in{$k}));
		}
	print &ui_confirmation_form(
		"restore.cgi",
		&text('rrun_rusure', join(", ", map { "<tt>$_->{'host'}</tt>" }
						(@servers, @missing))),
		\@hiddens,
		[ [ 'confirm', $text{'rrun_rusureok'} ] ],
		$text{'rrun_rusure2'},
		);
	return;
	}

# Show what is being done
$rcount = scalar(@servers) + scalar(@missing);
if ($backup->{'dest'}) {
	print "<b>",&text('rrun_destdesc', $rcount,
		    &nice_backup_destination($backup->{'dest'})),"</b><p>\n";
	}
else {
	print "<b>",&text('rrun_destdesc2', $rcount),"</b><p>\n";
	}

# Run the restore
&$indent_print();
$rv = &execute_restore($backup);
&$outdent_print();

# Print a summary line
@ok = grep { $rv->{$_->{'id'}} &&
	     $rv->{$_->{'id'}}->{'ok'} } (@servers, @missing);
@bad = grep { !$rv->{$_->{'id'}} ||
	      !$rv->{$_->{'id'}}->{'ok'} } (@servers, @missing);
if (scalar(@ok) == $rcount) {
	print "<b>",&text('rrun_allok', scalar(@ok)),"</b><p>\n";
	}
elsif (scalar(@ok)) {
	print "<b><font color=red>",
	      &text('rrun_somefailed', scalar(@ok), scalar(@bad)),
	      "</font></b><p>\n";
	}
else {
	print "<b><font color=red>",
	      &text('rrun_somefailed2', scalar(@bad)),
	      "</font></b><p>\n";
	}

# Show failure reasons
if (@bad) {
	print &ui_columns_start([ $text{'rrun_failhost'},
				  $text{'rrun_failreason'} ]);
	foreach $s (@bad) {
		print &ui_columns_row([
			$s->{'host'},
			$rv->{$s->{'id'}}->{'msg'},
			]);
		}
	print &ui_columns_end();
	}
&webmin_log("restore", "backup", $backup->{'id'},
	    { 'dest' => $backup->{'dest'},
	      'host' => join(' ', map { $_->{'host'} } (@servers, @missing)) });

if (@ok && defined(&theme_select_server)) {
	&theme_select_server($ok[0]);
	}

&ui_print_footer("", $text{'return'});

