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
	# Allow free choice of systems and source (Host, FTP or SSH)
	@allservers = grep { &supports_backup($_) }
			&list_available_managed_servers_sorted();
	@servers = grep { $want{$_->{'id'}} } @allservers;
	$backup = { 'servers' => join(' ', map { $_->{'id'} } @servers),
		    'parallel' => $in{'parallel'} };
	if ($in{'dest_mode'} == 3 || $in{'dest_mode'} == 4) {
		$dest = { 'mode' => $in{'dest_mode'} };
		$pfx = $in{'dest_mode'} == 3 ? 'ssh' : 'ftp';
		$err = &parse_backup_ssh_dest($dest, $pfx, \%in);
		&error($err) if ($err);
                $backup->{'dest'} = &join_backup_destination($dest);
		}
	}

# Double-check access to servers
foreach $s (@servers) {
	&can_action_error($s, "backup");
	}

&ui_print_unbuffered_header(undef, $text{'restore_title'}, "");

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
else {
	print "<b><font color=red>",
	      &text('rrun_somefailed', scalar(@ok), scalar(@bad)),
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

