#!/usr/local/bin/perl
# Actually backup a system

require './server-manager-lib.pl';
&error_setup($text{'onebackup_err'});
&can_action_error(undef, "backup");
&ReadParse();
my $server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "backup");

# Validate inputs and create backup object
my $backup = { 'servers' => $in{'id'} };
if ($in{'dest_mode'} == 7) {
	# To temp dir
	$tempdir = &transname();
	&make_dir($tempdir, 0700);
	$backup->{'dest'} = $tempdir;
	}
elsif ($in{'dest_mode'} == 2) {
	# Some other system
	$destserver = &get_managed_server($in{'vm2'});
	&can_action_error($destserver, "transfer");
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

# Execute the backup
if ($in{'mode'} == 7) {
	# To temp file, then display in browser
	# XXX
	# XXX stream output if possible
	}
else {
	# Show progress
	&ui_print_header(&server_in($server), $text{'onebackup_title'}, "");

	print "<b>",&text('onebackup_destdesc', $server->{'host'},
		    &nice_backup_destination($backup->{'dest'})),"</b><p>\n";

	# Execute it, and show output
	&$indent_print();
	$rv = &execute_backup($backup);
	&$outdent_print();

	# Show results
	if ($rv->{$server->{'id'}}->{'ok'}) {
		print $text{'create_done'},"<p>\n";
		}
	else {
		prunt &text('onebackup_failed', $rv->{$server->{'id'}}->{'msg'}),"<p>\n";
		}
	}

&webmin_log("backup", "backup", "oneoff",
	    { 'dest' => $backup->{'dest'}, 'host' => $server->{'host'} });
