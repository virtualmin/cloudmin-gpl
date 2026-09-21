package Cloudmin::Attempts;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use WebminCore qw(make_dir read_file_contents write_file_contents convert_to_json convert_from_json);

# key(token, [attempt]) keeps older API clients on their original job IDs.
sub key
{
my ($token, $attempt) = @_;
# Clients without attempt IDs retain token-based job identity.
return $token if (!defined($attempt) || $attempt eq '');
die "Invalid submission attempt\n" if (ref($attempt) || $attempt !~ /\A[a-f0-9]{32}\z/);
return $token.':attempt:'.$attempt;
}

# image_attempts(input) validates the optional per-image attempt identifiers.
sub image_attempts
{
my ($input) = @_;
# Non-browser clients may omit per-image attempts entirely.
return {} if (!$input->{'image_attempts'});
my $attempts = convert_from_json($input->{'image_attempts'});
die "Invalid image submission attempts\n" if (ref($attempts) ne 'HASH' || keys(%$attempts) > 16);
foreach my $attempt (values %$attempts) {
	# Reject empty entries; each supplied image needs a valid attempt ID.
	die "Invalid image submission attempts\n" if (!defined($attempt) || $attempt eq '');
	key('', $attempt);
	}
return $attempts;
}

1;
