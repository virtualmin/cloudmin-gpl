#!/usr/local/bin/perl
use strict;
use warnings;
use Encode ();
our (%in, %text);
require './server-manager-lib.pl';
# Only signed POST requests can change settings or mutes, or queue a test.
error('Use POST for notification changes')
	unless ($ENV{REQUEST_METHOD} || '') eq 'POST';
error('Request is too large') if ($ENV{CONTENT_LENGTH} || 0) > 32768;
ReadParse();
# Keep provider credentials out of generic error-page form dumps.
my %private = map { $_ => delete($in{$_}) }
	qw(telegram_token pushover_user pushover_token gotify_token);
# Webmin returns form bytes; the notification API and JSON store use characters.
my $decoded = eval {
	for my $field (qw(name target_name device email_address webhook_url
			 gotify_url address secret)) {
		next unless defined($in{$field});
		$in{$field} = Encode::decode('UTF-8', $in{$field},
			Encode::FB_CROAK | Encode::LEAVE_SRC);
		}
	1;
	};
# Keep malformed private fields out of the error page as well.
if (!$decoded) {
	delete @in{qw(secret webhook_url address)};
	error('Invalid UTF-8 in notification form');
	}
# Pass the signed token, a record ID in object and a mute scope in id.
my $action = $in{action} || '';
my %input = ( token => $in{token}, object => $in{object}, id => $in{id} );
# Both editors use the same mapping for provider-specific inputs.
my %address_fields = ( email => 'email_address', telegram => 'telegram_chat',
	gotify => 'gotify_url' );
# Inline switches submit only their state, never a stale copy of the record.
$input{enabled} = $in{enabled} || 0
	if $action =~ /\Aset_notification_(?:target|rule)_enabled\z/;
if ($action =~ /\Asave_notification_(target|rule)\z/) {
	# Pass only supported settings to the shared API validator.
	my $kind = $1;
	my %record = map { $_ => $in{$_} } grep { exists($in{$_}) }
		qw(name type address secret clear_secret enabled metric scope device
		threshold comparison duration cooldown reminder severity recovery targets);
	# Missing enabled input saves the record as disabled.
	$record{enabled} = 0 unless exists($record{enabled});
	if ($kind eq 'target') {
		# Map the selected form field to the shared target address.
		my $type = $in{type} || '';
		my $field = $address_fields{$type} || 'webhook_url';
		$record{address} = $in{$field} if exists($in{$field});
		$record{address} = $private{pushover_user}
			if $type eq 'pushover' &&
				defined($private{pushover_user});
		# Dedicated token fields replace the shared webhook token.
		$record{secret} = $private{$type.'_token'}
			if defined($private{$type.'_token'});
		}
	elsif (exists($in{delivery})) {
		# Save a new destination and its rule together.
		my $delivery = $in{delivery};
		error('Invalid notification delivery method')
			unless $delivery eq 'saved' || grep { $_ eq $delivery }
				Cloudmin::NotificationTypes::transports();
		if ($delivery ne 'saved') {
			# Inline creation carries only the selected
			# method's address and token.
			my $field = $address_fields{$delivery} || 'webhook_url';
			my $address = $delivery eq 'pushover'
				? $private{pushover_user} : $in{$field};
			my $secret =
				$delivery =~ /\A(?:telegram|pushover|gotify)\z/
				? $private{$delivery.'_token'} : $in{secret};
			$input{target} = {
				name => $in{target_name}, type => $delivery,
				address => $address, secret => $secret };
			}
		}
	if ($kind eq 'rule' && exists($in{scope_mode})) {
		# Hidden guest selections must not override other monitor modes.
		error('Invalid notification monitor mode') unless
			$in{scope_mode} =~ /\A(?:host|guests|all|selected)\z/;
		$record{scope} = $in{scope_mode} eq 'selected'
			? [ split(/[\s\0,]+/, $in{scope} || '') ]
			: $in{scope_mode};
		}
	# An existing object ID turns this save into an edit.
	$record{id} = $in{object} if $in{object};
	$input{$kind} = \%record;
	}
# The API applies permissions, token checks and transactional validation.
my $ok = eval { call_notification_api($action, \%input); 1 };
# Error pages must not receive bearer tokens or private webhook URLs.
delete @in{qw(secret webhook_url address)};
error(html_escape(error_message($@))) unless $ok;
# Return to the page that matches the change.
if ($action eq 'mute_notifications' || $action eq 'unmute_notifications') {
	# A guest mute returns to that guest's page, all to All Notifications.
	redirect('notifications.cgi'.(lc($in{id}) eq 'all'
		? '' : '?id='.urlize(lc($in{id}))));
	}
elsif ($action eq 'retry_notification') {
	# Retry results belong with their event in History.
	redirect('notifications.cgi?tab=history');
	}
else {
	# Other changes return to their rule or destination list.
	redirect('notifications.cgi?tab='.($action =~ /rule/ ? 'rules' : 'targets'));
	}
