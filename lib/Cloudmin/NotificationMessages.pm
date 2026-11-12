package Cloudmin::NotificationMessages;

# Build readable messages and provider requests without sending them.
use strict;
use warnings;
use Encode qw(encode decode is_utf8);
use JSON::PP ();
use URI ();
use File::Basename qw(dirname);
require(dirname(__FILE__).'/NotificationTypes.pm');

# Tests can override hosted API URLs without changing saved settings.
# Normal delivery uses each provider's HTTPS API.
our ($telegram_api_base, $pushover_api_base);

# characters(value) decodes UTF-8 bytes and leaves decoded text unchanged.
# An undefined value becomes an empty string.
sub characters
{
my ($value) = @_;
$value = '' unless defined($value);
return is_utf8($value) ? $value : decode('UTF-8', $value);
}

# render(event, translations, url) returns a translated subject and body.
# event contains the saved alert; translations holds notifications_ language
# keys. url links to host or guest history and must come from trusted settings.
sub render
{
my ($event, $translations, $url) = @_;
# tr(key, [values...]) fills numbered placeholders in a decoded translation.
my $tr = sub {
	my ($key, @values) = @_;
	my $text = characters($translations->{'notifications_'.$key});
	$text =~ s/\$(\d+)/defined($values[$1 - 1]) ? $values[$1 - 1] : ''/ge;
	return $text;
	};
# Keep the subject on one line, even when a saved name contains a line break.
# A test has no separate state, so its subject names it only once.
my $subject = $event->{phase} eq 'test'
	? $tr->('message_test_subject')
	: $tr->('message_subject', $event->{name}, $tr->($event->{phase}));
$subject =~ s/[\r\n]//g;
# Identify the host, affected resource and severity before the condition.
my @lines = (
	$tr->('message_host', $event->{host}),
	$tr->('message_subject_name', $event->{label}),
	$tr->('message_severity', $tr->($event->{severity})) );
my $definition = Cloudmin::NotificationTypes::metric($event->{metric});
if ($definition) {
	# Describe known conditions using their translated names.
	push @lines, $tr->('message_condition', $tr->($event->{metric}));
	if ($definition->{numeric}) {
		# Show the reading and threshold in the condition's units.
		my $unit = $definition->{unit};
		my $suffix = $unit eq '%' ? '%' : length($unit) ? ' '.$unit : '';
		my $reading = defined($event->{value})
			? sprintf('%.3f', $event->{value}) : '';
		$reading =~ s/\.?0+$//;
		push @lines, $tr->('message_reading', $reading, $suffix)
			if defined($event->{value});
		# A missing comparison means at or above.
		push @lines, $tr->('message_threshold',
			$tr->($event->{comparison} || 'ge'),
			$event->{threshold}, $suffix);
		}
	elsif ($definition->{boolean} && defined($event->{value})) {
		# Describe the problem or recovery in words.
		push @lines, $tr->(($event->{value} ? 'bad_' : 'clear_').
			$event->{metric});
		}
	# Job failures alert at once, so only sustained conditions show a wait.
	push @lines, $tr->('message_duration', $event->{duration})
		if $event->{duration} && $event->{phase} ne 'resolved' &&
			($definition->{numeric} || $definition->{boolean});
	}
else {
	# Tests explain delivery without claiming a monitored problem exists.
	push @lines, $tr->('message_test') if $event->{phase} eq 'test';
	}
# Include the event time, ID and history link for follow-up.
push @lines, $tr->('message_time', scalar(gmtime($event->{created}))),
	$tr->('message_id', $event->{id});
push @lines, $url if length($url || '');
return { subject => $subject, body => join("\n", @lines)."\n" };
}

# request(target, event, message) builds a POST URL, headers and UTF-8 body.
# Generic webhooks retain the versioned event format. Chat services receive
# readable text in their own format.
sub request
{
my ($target, $event, $message) = @_;
my $type = $target->{type};
my $url = URI->new($target->{address});
# Give receivers a stable key to recognize retries of the same event.
my %headers = (
	'Content-Type' => 'application/json',
	'Idempotency-Key' => 'cloudmin-'.$event->{instance}.'-'.$event->{id} );
# Only webhook methods use the shared bearer token header.
$headers{Authorization} = 'Bearer '.$target->{secret}
	if $type !~ /\A(?:telegram|pushover|gotify)\z/ &&
		length($target->{secret} || '');
# Generic webhooks receive the event; chat services receive readable text.
my $body = $type eq 'webhook' ? ''
	: $message->{subject}."\n\n".$message->{body};
my $payload;
if ($type eq 'webhook') {
	# Stored event strings are already characters; JSON encodes them once.
	$payload = { %$event };
	}
elsif ($type eq 'slack') {
	# Plain text blocks prevent names from becoming mentions or markup.
	$body = substr($body, 0, 3000);
	$payload = { text => $message->{subject}, mrkdwn => JSON::PP::false,
		parse => 'none', unfurl_links => JSON::PP::false,
		unfurl_media => JSON::PP::false,
		blocks => [ { type => 'section', text => {
			type => 'plain_text', text => $body } } ] };
	}
elsif ($type eq 'discord') {
	# Wait for message creation while preserving thread_id and other fields.
	my @query = $url->query_form();
	my @kept;
	while (@query) {
		my ($key, $value) = splice(@query, 0, 2);
		push @kept, $key, $value unless $key eq 'wait';
		}
	$url->query_form(@kept, wait => 'true');
	$payload = { content => substr($body, 0, 2000),
		allowed_mentions => { parse => [ ] } };
	}
elsif ($type eq 'teams') {
	# Workflows accept Adaptive Cards through the Teams webhook trigger.
	$payload = { type => 'message', attachments => [ {
		contentType => 'application/vnd.microsoft.card.adaptive',
		contentUrl => undef, content => {
			'$schema' => 'http://adaptivecards.io/schemas/adaptive-card.json',
			type => 'AdaptiveCard', version => '1.2',
			body => [ { type => 'TextBlock', text => $body,
				wrap => JSON::PP::true } ] } } ] };
	}
elsif ($type eq 'telegram') {
	# Send plain text and authenticate through the Bot API URL path.
	$url = URI->new(($telegram_api_base || 'https://api.telegram.org').
		'/bot'.$target->{secret}.'/sendMessage');
	# Numeric chat IDs are sent as JSON numbers; usernames stay text.
	# Telegram limits text to 4096 characters.
	$payload = {
		chat_id => $target->{address} =~ /\A-?[0-9]+\z/
			? 0 + $target->{address} : $target->{address},
		text => substr($body, 0, 4096),
		link_preview_options => { is_disabled => JSON::PP::true } };
	}
elsif ($type eq 'pushover') {
	# Pushover accepts credentials in JSON and counts limits in characters.
	$url = URI->new(($pushover_api_base || 'https://api.pushover.net').
		'/1/messages.json');
	$payload = { token => $target->{secret}, user => $target->{address},
		title => substr($message->{subject}, 0, 250),
		message => substr($message->{body}, 0, 1024), priority => 0 };
	}
elsif ($type eq 'gotify') {
	# Preserve reverse-proxy prefixes and keep the token out of the URL.
	my $path = $url->path;
	$path =~ s{/+\z}{};
	$url->path($path.'/message');
	$headers{'X-Gotify-Key'} = $target->{secret};
	$payload = { title => $message->{subject},
		message => $message->{body}, priority => 5 };
	}
elsif ($type eq 'ntfy') {
	# Publish to the topic URL, including on self-hosted ntfy servers.
	# ntfy limits text messages to 4096 bytes, not characters.
	$headers{'Content-Type'} = 'text/plain; charset=utf-8';
	$headers{Priority} = $event->{severity} eq 'error' ? 5
		: $event->{severity} eq 'warning' ? 4 : 3;
	$body = substr($body, 0, -1) while length(encode('UTF-8', $body)) > 4096;
	return { url => "$url", headers => \%headers,
		content => encode('UTF-8', $body) };
	}
else {
	# An unknown delivery method has no safe request format.
	die "Unknown notification delivery method\n";
	}
# Every other method sends its payload as JSON.
return { url => "$url", headers => \%headers,
	content => JSON::PP->new->canonical->utf8->encode($payload) };
}

1;
