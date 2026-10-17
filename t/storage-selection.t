use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use CloudminTest;
use Test::More;

our $module_root_directory = "$Bin/..";
our $remote_user = 'fixture';
require "$Bin/../cloudmin-storage-lib.pl";

{
	package SelectionTokens;
	# check_token(self, owner, token) accepts only the fixture form token.
	sub check_token { die "Expired token\n" if ($_[2] || '') ne 'valid'; }
	package SelectionStorage;
	# inspect_volume(self, uuid, name) models ownership and a stable review.
	sub inspect_volume {
		my ($self, $uuid, $name) = @_;
		die "Owned volume\n" if $name eq 'owned.raw';
		return (undef, undef, {uuid => $uuid, name => $name, pool => 'pool',
			key => $name, path => '/fixture/'.$name, revision => 'a' x 64});
	}
	# delete_volume(self, uuid, name, revision, confirm) records confirmed
	# removals and injects a native failure for the selected fixture.
	sub delete_volume {
		my ($self, $uuid, $name, $revision, $confirm) = @_;
		die "Native failure\n" if $name eq 'failure.raw';
		die "Missing confirmation\n" if $confirm ne '1';
		push(@{$self->{'deleted'}}, $name);
		return ($self->inspect_volume($uuid, $name))[2];
	}
}
my $service = bless({deleted => []}, 'SelectionStorage');
my (@logs, $readonly);
{
	no warnings qw(redefine once);
	*get_storage_service = sub { $service };
	*get_image_jobs = sub { bless({}, 'SelectionTokens') };
	*is_readonly_mode = sub { $readonly };
	*webmin_log = sub { push(@logs, [@_]) };
	*error_message = sub { my $s = $_[0]; $s =~ s/\s+$//; $s };
}
my $uuid = '11111111-2222-3333-4444-555555555555';
my %input = (token => 'valid', volume => "$uuid/one.raw\0$uuid/two, & <special>.raw");
local $ENV{'REQUEST_METHOD'} = 'POST';
my $selection = storage_volume_selection(\%input);
is_deeply([map { $_->{'name'} } @$selection], ['one.raw', 'two, & <special>.raw'], 'names with commas and markup stay paired with their pools');
my $review = review_storage_volumes(\%input);
is(scalar(@$review), 2, 'all selected files are reviewed');
is_deeply($service->{'deleted'}, [], 'review cannot delete');

# Reject invalid or ambiguous selections before reaching deletion.
for my $value ('', "$uuid/", 'wrong/disk', "$uuid/a\0$uuid/a", join("\0", map { "$uuid/$_" } 1..101)) {
	ok(!eval { storage_volume_selection({volume => $value}); 1 }, 'invalid selection refused');
}
for my $revision ('', 'a' x 64, ('a' x 64)."\0bad") {
	ok(!eval { storage_volume_selection({%input, revision => $revision}, 1); 1 }, 'missing or mismatched revisions refused');
}
my %confirmed = (%input, confirm => 1, revision => join("\0", map { $_->{'revision'} } @$review));
{
	local $ENV{'REQUEST_METHOD'} = 'GET';
	for my $operation (sub { review_storage_volumes(\%input) }, sub { change_storage('delete_volumes', \%confirmed) }) {
		ok(!eval { $operation->(); 1 }, 'review and deletion require POST');
		like($@, qr/Use the Storage form/, 'POST refusal explained');
	}
}
for my $operation (sub { review_storage_volumes(\%input) }, sub { change_storage('delete_volumes', \%confirmed) }) {
	$readonly = 1;
	ok(!eval { $operation->(); 1 }, 'read-only account refused');
	$readonly = 0;
}
for my $action ('review', 'delete') {
	my %bad = (%confirmed, token => 'invalid');
	ok(!eval { $action eq 'review' ? review_storage_volumes(\%bad) : change_storage('delete_volumes', \%bad); 1 }, 'invalid token refused');
}
ok(!eval { change_storage('delete_volumes', {%confirmed, confirm => 0}); 1 }, 'separate confirmation required');
ok(!eval { change_storage('delete_volumes', {%confirmed, revision => ('a' x 64)."\0".('b' x 64)}); 1 }, 'stale second volume refuses entire selection');
ok(!eval { change_storage('delete_volumes', {%confirmed, volume => "$uuid/one.raw\0$uuid/owned.raw"}); 1 }, 'owned second volume refuses entire selection');
is_deeply($service->{'deleted'}, [], 'preflight refusals preserve every file');
is_deeply(\@logs, [], 'refusals create no deletion audit');

# The existing single-volume service guards each write; successes are audited.
like(change_storage('delete_volumes', \%confirmed), qr/one.raw.*two, & <special>.raw/, 'valid selection deletes both files');
is_deeply($service->{'deleted'}, ['one.raw', 'two, & <special>.raw'], 'only selected files reach guarded deletion');
is(scalar(@logs), 2, 'each deletion gets an audit entry');
$service->{'deleted'} = [];
@logs = ();
ok(!eval { change_storage('delete_volumes', {%confirmed, volume => "$uuid/one.raw\0$uuid/failure.raw"}); 1 }, 'native failure reported');
like($@, qr/Deleted: pool\/one.raw.*Could not delete: pool\/failure.raw: Native failure/, 'partial failure names successes and failures');
is(scalar(@logs), 1, 'successful deletion remains audited after partial failure');
done_testing();
