package Cloudmin::BackupSSH;

# OpenSSH verifies transfers; this module supplies trusted entries and approvals.
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Temp qw(tempfile);
use Fcntl qw(:DEFAULT :flock O_NOFOLLOW);
use Digest::SHA qw(sha256_hex sha256_base64);
use MIME::Base64 qw(decode_base64);
require(dirname(__FILE__).'/Worker.pm');
require(dirname(__FILE__).'/SSHKeys.pm');
our $directory;
our @known_files = ('/etc/ssh/ssh_known_hosts', ((getpwuid(0))[7] || '/root').'/.ssh/known_hosts');

# host(target) validates and normalizes the OpenSSH known_hosts lookup name.
sub host
{
my ($t) = @_;
die "Enter a valid SSH server and port\n" if (($t->{'host'} || '') !~ /\A[a-zA-Z0-9][a-zA-Z0-9.:-]*\z/ ||
	($t->{'port'} || 22) !~ /\A\d+\z/ || ($t->{'port'} || 22) > 65535);
return ($t->{'port'} || 22) == 22 ? lc($t->{'host'}) : '['.lc($t->{'host'}).']:'.(0+$t->{'port'});
}

# entries(file, host) delegates hashed names, patterns and markers to OpenSSH.
sub entries
{
my ($file, $host) = @_;
# An absent trust file is normal; a failed lookup must not look like no trust.
return () if (!-e $file);
open(my $fh, '-|', 'ssh-keygen', '-F', $host, '-f', $file) or die "Cannot read SSH known hosts\n";
my @lines = grep { !/^#/ && /\S/ } <$fh>;
close($fh);
# ssh-keygen exits with 1 for no match; other failures need attention.
die "Cannot read SSH known hosts\n" if ($? && $? != 256);
chomp(@lines);
return @lines;
}

1;
