use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore;
use Test::More;
our (%in, %text);
# Load the real editor hooks with Webmin widgets, without initializing a host.
$INC{'server-manager-lib.pl'} = 1;
require "$Bin/../acl_security.pl";
my $id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
my $stale = '11111111-2222-3333-4444-555555555555';
no warnings 'redefine';
# error(message) throws so the test can check rejected submissions.
local *main::error = sub { die $_[0]; };
my $inventory = bless({}, 'EditorInventory');
# get_libvirt() returns a host inventory fixture without connecting to libvirt.
local *main::get_libvirt = sub { return $inventory; };
# list_domains(self) supplies a guest name that must be escaped in the editor.
local *EditorInventory::list_domains = sub {
	return [{uuid => $id, name => '<script>guest</script>'}];
};
# list_managed_servers_sorted() catches accidental use of the editor's VM scope.
local *main::list_managed_servers_sorted = sub {
	die 'The ACL editor must not use the editor\'s filtered VM list';
};
$text{'acl_invalid_vm'} = 'Invalid VM';
# Saving reads Webmin's shared form input, lowercases UUIDs and removes duplicates.
my %saved;
%in = (admin => 0, vms => uc($id)."\0$id", power => 1, console => 1);
acl_security_save(\%saved);
is_deeply(\%saved, {admin => 0, vms => $id, power => 1, force => 0,
	console => 1, terminal => 0, password => 0, noconfig => 1}, 'editor saves explicit grants and forbids host configuration');
# Password reset can be delegated without granting power controls.
%in = (admin => 0, vms => $id, password => 1);
acl_security_save(\%saved);
is($saved{'password'}, 1, 'password reset has its own saved grant');
is($saved{'power'}, 0, 'password reset does not grant power controls');
# Only the host administrator role permits module configuration.
%in = (admin => 1);
acl_security_save(\%saved);
is($saved{'noconfig'}, 0, 'administrator can configure module');
# Names, wildcards and path-like values must not become assignments.
for my $value ('*', 'guest-name', "$id\0../host", 'id='. $id) {
	%in = (admin => 0, vms => $value);
	ok(!eval { acl_security_save(\%saved); 1 }, 'invalid assignment is refused');
	like($@, qr/Invalid VM/, 'invalid assignment has clear error');
}
# Keep assignments to missing VMs and escape VM names when rendering the form.
my $html;
open(my $out, '>', \$html) or die $!;
{
	local *STDOUT = $out;
	print ui_table_start(undef, undef, 4);
	acl_security_form({admin => 0, vms => "$id $stale", power => 1});
}
like($html, qr/\Q$id\E/, 'current VM can be assigned');
like($html, qr/\Q$stale\E/, 'missing VM assignment survives unrelated edits');
unlike($html, qr/<script>/, 'VM names cannot inject HTML into permission editor');
done_testing();
