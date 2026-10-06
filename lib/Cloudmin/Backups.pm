package Cloudmin::Backups;

# Full backups preserve guest identity; only clones prepare a new identity.
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempfile);
use Digest::SHA qw(sha256_hex);
use JSON::PP qw(encode_json decode_json);
use POSIX qw(strftime);
use Fcntl qw(:DEFAULT O_NOFOLLOW);
require(dirname(__FILE__).'/Clones.pm');
our @ISA = ('Cloudmin::Clones');

# directory(self) creates private metadata storage outside the web root.
sub directory
{
my ($self) = @_;
my $dir = $self->{'directory'};
# Credentials and secure XML must remain private even in an existing directory.
make_path($dir, {mode => 0700}) if (!-e $dir);
my @st = lstat($dir);
die "Unsafe backup metadata directory\n" if (!@st || !-d _ || -l _ || $st[4] != $> || ($st[2] & 0077));
return $dir;
}

1;
