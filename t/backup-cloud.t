use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);

# Use an installed Pro extension or its sibling checkout;
# skip if neither exists.
my ($helpers) =
	grep { -r $_ } ( "$Bin/../pro/BackupCloud.pm",
			 "$Bin/../../cloudmin-pro/BackupCloud.pm" );
plan skip_all => 'Cloudmin Pro provider helpers are not installed'
	if (!$helpers);
require $helpers;
my $work = tempdir(CLEANUP => 1);
my $archive = "$work/archive";
open(my $fh, '>', $archive) or die $!;
print($fh 'backup fixture'); close($fh);

# Dropbox errors contain structured objects, while successful transfers return
# objects too. Error objects must become text before reaching the upload helper.
{
	no warnings qw(redefine once);
	local %Cloudmin::BackupCloud::config =
		( dropbox_token => 'fixture-token' );
	my $reply;
	local *Cloudmin::BackupCloud::http_post_file =
		sub { ${$_[4]} = encode_json($reply); };
	local *Cloudmin::BackupCloud::http_post =
		sub { ${$_[4]} = encode_json($reply); };
	$reply = { name => 'archive', id => 'fixture-id' };
	is(Cloudmin::BackupCloud::upload_dropbox_file('backups', 'fixture.tar',
						      $archive, 1), undef,
	   'Dropbox accepts a successful upload');
	for my $error (
		{ error => { '.tag' => 'path' }, error_summary =>
							 'path/insufficient_space/' },
		{ error => { '.tag' => 'invalid_access_token' } },
		{ error => 'invalid_request' } ) {
		$reply = $error;
		my $upload =
			Cloudmin::BackupCloud::upload_dropbox_file(
				'backups',
				'fixture.tar', $archive, 1);
		ok(defined($upload) && !ref($upload) && length($upload),
		   'Dropbox upload error is never treated as success');
		my $delete =
			Cloudmin::BackupCloud::delete_dropbox_path(
				'backups',
				'fixture.tar');
		ok(defined($delete) && !ref($delete) && length($delete),
		   'Dropbox delete error is never treated as success');
		}
	}
done_testing();
