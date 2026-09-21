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

1;
