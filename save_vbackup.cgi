#!/usr/local/bin/perl
# Create, update or delete a virtualmin backup config

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'vbackup_err'});
&error_if_cloudmin_replica();
&can_action_error(undef, "domains");

if (!$in{'new'}) {
	$vbackup = &get_virtualmin_backup($in{'id'});
        $vbackup || &error($text{'vbackup_egone'});
	&can_virtualmin_backup($vbackup) || &error($text{'vbackup_ecannot'});
	}

if ($in{'delete'}) {
	# Just remove this replication config
	@srcs = &get_virtualmin_backup_srcs($vbackup);
	@doms = split(/\s+/, $vbackup->{'doms'});
	&delete_virtualmin_backup($vbackup);
	&webmin_log("delete", "vbackup", $srcs[0]->{'host'},
		    { 'doms' => \@doms });
	}
elsif ($in{'run'}) {
	# Redirec to execute page
	&redirect("exec_vbackup.cgi?id=$in{'id'}");
	return;
	}
else {
	# Validate inputs, starting with source systems
	@srcids = split(/\r?\n/, $in{'src'});
	@srcids || &error($text{'vbackup_esrcs'});
	foreach $id (@srcids) {
		$src = &get_managed_server($id);
		$src && &can_action($dest, "domains") ||
			&error($text{'vbackup_esrc'});
		}
	$vbackup->{'src'} = join(" ", @srcids);
	@srcs = &get_virtualmin_backup_srcs($vbackup);

	# Parse list of backup URLs
	@dests = split(/\r?\n/, $in{'dest'});
	@dests || &error($text{'vbackup_edests'});
	foreach $dest (@dests) {
		# XXX
		}

	# Parse domains
	@doms = split(/\r?\n/, $in{'doms'});
	$vbackup->{'doms'} = join(" ", @doms);
	%srcdoms = map { $_->{'dom'}, $_ } &get_server_domains($src);
	foreach $dname (@doms) {
		$srcdoms{$dname} ||
		    &error(&text('vbackup_edomon', &show_domain_name($dname)));
		}
	$vbackup->{'doms_all'} = $in{'doms_all'};

	# Parse global settings
	$vbackup->{'tmpls'} = join(" ", split(/\0/, $in{'tmpl'}));
	$vbackup->{'doms'} || $vbackup->{'tmpls'} || $vbackup->{'doms_all'} ||
		&error($text{'vbackup_edoms'});
	
	# Parse schedule
	$vbackup->{'enabled'} = $in{'enabled'};
	&virtualmin_ui_parse_cron_time("when", $vbackup, \%in);

	# Parse email
	if ($in{'emailother'}) {
		$in{'email'} =~ /^\S+\@\S+$/ ||
			&error($text{'vbackup_eemail'});
		$vbackup->{'email'} = $in{'email'};
		}
	else {
		delete($vbackup->{'email'});
		}
	if (!$access{'owner'}) {
		$vbackup->{'emailmaster'} = $in{'emailmaster'};
		}

	# Update or create backup
	&save_virtualmin_backup($vbackup);

	&webmin_log($in{'new'} ? "create" : "modify", "vbackup",
		    $srcs[0]->{'host'}, { 'doms' => \@doms });
	}
&redirect("list_vbackups.cgi");

