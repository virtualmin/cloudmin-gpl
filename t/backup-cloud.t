use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use File::Temp qw(tempdir);
use Encode qw(encode is_utf8);

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
		sub { ${$_[4]} = WebminCore::convert_to_json($reply, 0, 1); };
	local *Cloudmin::BackupCloud::http_post =
		sub { ${$_[4]} = WebminCore::convert_to_json($reply, 0, 1); };
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
# Provider replies are UTF-8 bytes, including OAuth errors and file names.
{
	no warnings qw(redefine once);
	local %Cloudmin::BackupCloud::config =
		( dropbox_token => 'fixture-token' );
	my $reply = encode('UTF-8', '{"name":"é東京😀","id":"fixture"}');
	my $body;
	local *Cloudmin::BackupCloud::http_post = sub {
		$body = $_[3]; ${$_[4]} = $reply;
		};
	my $result = Cloudmin::BackupCloud::call_dropbox_api('/fixture',
		[ [ 'path', '/é東京😀' ] ]);
	is($result->{name}, 'é東京😀', 'Dropbox decodes UTF-8 metadata');
	is_deeply(WebminCore::convert_from_json($body), { path => '/é東京😀' },
		  'Dropbox request preserves Unicode paths');
	ok(!is_utf8($body), 'Dropbox sends bytes');
	unlike($body, qr/[\r\n]/, 'Dropbox arguments fit in one HTTP header');
	$reply = encode('UTF-8',
		'{"error":"invalid_grant","error_description":"é東京😀"}');
	my ($ok, $error) = Cloudmin::BackupCloud::get_oauth_access_token(
		{ rtoken => 'fixture', clientid => 'fixture', secret => 'fixture' }, 1);
	is($ok, 0, 'OAuth rejection remains an error');
	is($error, 'é東京😀', 'OAuth error preserves Unicode');
	$reply = '{broken';
	like(Cloudmin::BackupCloud::call_dropbox_api('/fixture', [ ]),
	     qr/JSON decoding/, 'invalid provider JSON remains a handled error');
	}

# Content-Length must count encoded bytes, not decoded Unicode characters.
{
	no warnings qw(redefine once);
	my (@headers, $body);
	local *Cloudmin::BackupCloud::make_http_connection = sub {
		@headers = @{$_[5]}; return { };
		};
	local *Cloudmin::BackupCloud::write_http_connection =
		sub { $body = $_[1]; };
	local *Cloudmin::BackupCloud::complete_http_download = sub { };
	Cloudmin::BackupCloud::http_post_json('fixture.invalid', 80, '/',
		{ name => 'é東京😀', enabled => \1 }, \my $out, \my $error);
	my %headers = map { @$_ } @headers;
	is($headers{'Content-length'}, length($body) - 2,
	   'HTTP length matches the UTF-8 body without its trailing CRLF');
	ok(!is_utf8($body), 'HTTP JSON body is binary');
	is(WebminCore::convert_from_json($body)->{name}, 'é東京😀',
	   'HTTP JSON body preserves Unicode');
	like($body, qr/"enabled"\s*:\s*true/, 'HTTP flags remain booleans');
	}
done_testing();
