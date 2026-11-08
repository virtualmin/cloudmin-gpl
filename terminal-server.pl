#!/usr/bin/perl
# Authorize one guest SSH target and supervise its isolated browser relay.
use strict;
use warnings;
require './server-manager-lib.pl';
require './cloudmin-terminal-lib.pl';
require './cloudmin-relay-lib.pl';
require './cloudmin-status-lib.pl';
our ($session_id, $remote_user);
our $error_must_die = 1;
my ($port, $id, $uuid, $username, $address, $ssh_port, $auth) = @ARGV;
# Reject a missing session or malformed identities before querying libvirt.
die "Invalid terminal arguments\n" if (!$session_id ||
				       ($id || '') !~ /\A[a-f0-9]{32}\z/ ||
				       ($uuid || '') !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/i);
# Recheck the terminal grant, current guest addresses and key ownership.
require_access('terminal', $uuid);
my $vm = get_libvirt(1)->get_domain($uuid) ||
	 die "Virtual machine not found\n";
my $request = parse_terminal_request($vm,
				     { username => $username,
				       address => $address, port => $ssh_port,
				       auth => $auth });
# authorized() checks this session's current grant for the selected guest.
my $authorized = sub {
	my $access = session_access($session_id);
	return $access && $access->{'policy'}->allows('terminal', $uuid);
	};
# Track authentication separately from whether saving preferences succeeds.
my $authenticated = 0;
# command(credential_path) uses the revalidated destination and selected key.
run_interactive_relay($port, "cloudmin-terminal-$id", sub {
	build_terminal_command($request, $id, $remote_user, $_[0]);
	}, undef, $authorized, sub {
		# connected() records login success while access remains valid.
		return if (!$authorized->());
		$authenticated = 1;
		# Failed preference writes must not close an
		# authenticated terminal.
		eval { save_terminal_login($uuid, $id, 'connected'); };
		warn "Cannot remember SSH connection: $@" if ($@);
		my $saved =
			eval { save_terminal_port($uuid,
						  $request->{'port'}); 1 };
		if ($saved) {
			# Refresh the shared status probe without waiting
			# for its normal backoff.
			notify_status_changed($uuid);
			}
		else {
			# A preferences write failure must not
			# disconnect a working terminal.
			warn "Cannot remember SSH port: $@";
			}
		}, sub {
			# finished() records failed login only while
			# access remains valid.
			save_terminal_login($uuid, $id, 'failed')
				if (!$authenticated && $authorized->());
			});
