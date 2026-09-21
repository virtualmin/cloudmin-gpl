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

# new(class, directory => path, lock => callback) stores attempt IDs only.
# lock(name, callback) serializes choices made by concurrent browser requests.
sub new
{
my ($class, %options) = @_;
return bless(\%options, $class);
}

# choose(self, scope, previous, proposed, inspect) selects one submission ID.
# previous is empty on first submission; scope binds an owner, token and action.
# inspect(attempt) returns true only after a failed job has finished cleanup.
# Persist the successor before replying, so lost replies and racing retries
# select the same attempt even if its job has already finished.
sub choose
{
my ($self, $scope, $previous, $proposed, $inspect) = @_;
# Validate both identifiers before deriving or opening the scope's state file.
key('', $proposed);
die "Missing submission attempt\n" if (!$proposed);
key('', $previous);
my $name = sha256_hex($scope);
return $self->{'lock'}->('attempt-'.$name, sub {
    local $main::error_must_die = 1;
    make_dir($self->{'directory'}, 0700, 1) || die "Cannot create attempt directory\n";
    my $path = "$self->{directory}/$name.json";
    my $record = -f $path ? convert_from_json(read_file_contents($path)) : undef;
    if (!$record) {
        # Signed tokens expire after a day; discard only older attempt records.
        opendir(my $dir, $self->{'directory'}) || die "Cannot read attempt directory\n";
        foreach my $file (readdir($dir)) {
            next if ($file !~ /\A[a-f0-9]{64}\.json\z/);
            my $old = "$self->{directory}/$file";
            unlink($old) if ((stat($old))[9] < time()-172800);
        }
        closedir($dir);
        # Concurrent submissions, including other tabs, share the first attempt.
        $record = { first => $proposed, next => {} };
    }
    elsif (!$previous) {
        # A lost initial reply must return the same first attempt.
        return $record->{'first'};
    }
    else {
        # Only a known attempt may request a successor for this form.
        die "Unknown submission attempt; reload the form\n"
            if ($previous ne $record->{'first'} &&
                !grep { $_ eq $previous } values %{$record->{'next'}});
        # Repeated checks return the same replacement, even if it also failed.
        return $record->{'next'}->{$previous} if ($record->{'next'}->{$previous});
        # Keep active, successful or unsubmitted attempts on their current ID.
        return $previous if (!$inspect->($previous));
        die "Retry needs a new attempt identifier\n" if ($proposed eq $record->{'first'} ||
            grep { $_ eq $proposed } values %{$record->{'next'}});
        $record->{'next'}->{$previous} = $proposed;
    }
    # Save before replying; stale records are pruned after token expiry.
    my $mask = umask(0077);
    my $ok = eval { write_file_contents($path, convert_to_json($record)); 1 };
    my $error = $@;
    umask($mask);
    die $error if (!$ok);
    return $proposed;
    });
}

1;
