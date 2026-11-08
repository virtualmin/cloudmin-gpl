#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user);
require './server-manager-lib.pl';
my $result;
my $ok = eval {
	# Only host administrators may probe a destination or
	# change shared trust.
	require_access('host');
	die "Changes are disabled in read-only mode\n" if (is_readonly_mode());
	die "SSH host checks require POST\n"
		if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
	die "Request is too large\n" if (($ENV{'CONTENT_LENGTH'} || 0) > 16384);
	ReadParse();
	get_image_jobs()->check_token($remote_user, $in{'token'});
	my $target = { host => $in{'host'}, port => $in{'port'} || 22 };
	if ($in{'backup'}) {
		# Use the saved address for listed archives; the
		# probe needs no login.
		my $record = get_backup_service()->record($in{'backup'}) ||
			     die "Backup not found\n";
		$target = $record->{'target'};
		}
	# Listed local or cloud archives need no SSH probe.
	if ($in{'backup'} && $target->{'mode'} ne 'ssh') {
		$result = { status => 'trusted' };
		}
	# Approval requires write admission, then rescans before
	# saving shared trust.
	elsif (($in{'action'} || '') eq 'trust') {
		require_access('manage');
		$result =
			Cloudmin::BackupSSH::approve($target, $in{'previous'},
						     $in{'proposed'});
		webmin_log('trust', 'backup_host', $result->{'host'});
		}
	# Read-only probes return fingerprints, without
	# publishing raw key material.
	else {
		die "Unknown SSH host check action\n"
			if (($in{'action'} || '') ne 'check');
		$result = Cloudmin::BackupSSH::check($target);
		delete($result->{'keys'});
		if ($result->{'status'} ne 'trusted') {
			# Escape remote data before rendering the
			# fingerprint confirmation card.
			my $body =
				ui_p(ui_tag('tt', html_escape(
					$result->{'host'}))).
				ui_p($text{'backup_host_verify'});
			foreach my $which (qw(old current)) {
				# Unknown hosts have no old
				# fingerprint list to display.
				next if (!@{$result->{$which}});
				$body .= ui_field($text{'backup_host_'.$which},
						  ui_tag('pre',
							 html_escape(join("\n",
									  @{$result->{$which}}))));
				}
			$body .= ui_cluster([
				ui_action_button(
					$text{$result->{'status'} eq 'changed'
						? 'backup_host_replace'
						: 'backup_host_trust'},
					'primary',
					{ attrs => { 'data-backup-host-trust' => 1 } }),
				ui_action_button($text{'backup_host_cancel'},
						 'neutral',
						 { attrs => {
							 'data-backup-host-cancel' => 1 } }) ]);
			$result->{'html'} =
				ui_card({ title =>
						  $text{'backup_host_'.$result->{'status'}}, body =>
												     $body });
			}
		}
	1;
	};
# Trust results must not be cached; JSON failures stay inside this endpoint.
my $error = error_message($@) if (!$ok);
print "Cache-Control: no-store\r\n";
print_json($ok ? $result : { error => $error }, 0, 1);
