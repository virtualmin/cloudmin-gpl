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
	$server = &get_managed_server_by("id", $backuplog->{'server'});
	@servers = ( $server );
	$backup = { 'servers' => $server->{'id'},
		    'dest' => $backuplog->{'dest'},
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
if ($backup->{'dest'}) {
	print "<b>",&text('rrun_destdesc', scalar(@servers),
		    &nice_backup_destination($backup->{'dest'})),"</b><p>\n";
	}
else {
	print "<b>",&text('rrun_destdesc2', scalar(@servers)),"</b><p>\n";
	}

# Run the restore
&$indent_print();
$rv = &execute_restore($backup);
&$outdent_print();

# Print a summary line
@ok = grep { $rv->{$_->{'id'}} &&
	     $rv->{$_->{'id'}}->{'ok'} } @servers;
@bad = grep { !$rv->{$_->{'id'}} ||
	      !$rv->{$_->{'id'}}->{'ok'} } @servers;
if (scalar(@ok) == scalar(@servers)) {
	print "<b>",&text('rrun_allok', scalar(@ok)),"</b><p>\n";
	}
else {
	print "<b><font color=red>",
	      &text('rrun_somefailed', scalar(@ok), scalar(@bad)),
	      "</font></b><p>\n";
	}

# Show failure reasons
print "<table>\n";
foreach $s (@bad) {
	print "<tr> <td>$s->{'host'}</td> <td>:</td> <td>$rv->{$s->{'id'}}->{'msg'}</td> </tr>\n";
	}
print "</table>\n";

&ui_print_footer("", $text{'return'});

