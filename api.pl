#!/usr/bin/perl
# api.pl action
# Local CLI for the v1 Cloudmin API. Actions with input read JSON from stdin.
use strict;
use warnings;
use FindBin qw($Bin);
BEGIN {
	die "Run this command as root on the Cloudmin Linux host\n"
		unless $^O eq 'linux' && $< == 0;
	$ENV{'WEBMIN_CONFIG'} ||= '/etc/webmin';
	$ENV{'WEBMIN_VAR'} ||= '/var/webmin';
	$ENV{'REMOTE_USER'} = 'root';
	# Webmin resolves the module from $0, even for relative CLI invocations.
	$0 = "$FindBin::Bin/$FindBin::Script";
	chdir($FindBin::Bin) || die $!;
	}
require './server-manager-lib.pl';
my $action = shift(@ARGV) || 'options';
my $input = {};
my $ok = eval {
	# Only actions with request fields read stdin.
	if ($action !~ /\A(?:options|list|backups|bridges|storage|license)\z/) {
		# Machine and saved-key inventories accept optional selectors. Other
		# actions require JSON, even bridge_status with no transaction ID.
		die "Supply a JSON object on stdin\n" if (-t STDIN && $action !~ /\A(?:machines|ssh_keys)\z/);
		# An extra byte distinguishes an oversized request from EOF.
		my $body = '';
		read_fully(\*STDIN, \$body, 131073) unless (-t STDIN && $action =~ /\A(?:machines|ssh_keys)\z/);
		die "Request is too large\n" if (length($body) > 131072);
		# An empty inventory body selects all visible records; other
		# actions need a request object rather than a parser error.
		die "Supply a JSON object on stdin\n"
			if ($body !~ /\S/ && $action !~ /\A(?:machines|ssh_keys)\z/);
		$input = $body =~ /\S/ ? convert_from_json($body) : {};
		die "Request must be a JSON object\n"
			if (ref($input) ne 'HASH');
		}
	# Local root reviews and mutations retain the browser token contract.
	$input->{'token'} ||= get_image_jobs()->form_token('root')
		if ($action !~ /\A(?:options|machines|settings|status|list|snapshots|clone_options|image_options|backups|bridges|bridge_status|storage|license|ssh_keys|guest_ssh_keys)\z/);
	my $result = call_vm_api(1, $action, $input);
	# Options give clients a token for their subsequent creation request.
	$result->{'token'} = get_image_jobs()->form_token('root')
		if ($action eq 'options');
	print convert_to_json({ version => 1, result => $result }, 0, 1), "\n";
	1;
	};
if (!$ok) {
	# CLI failures go to stderr, without a JSON result on stdout.
	print STDERR error_message($@), "\n";
	exit(1);
	}
