package Cloudmin::Access;

# Module permissions are independent of Webmin rendering and libvirt access.
use strict;
use warnings;

# new(class, acl, [readonly]) builds the effective permissions.
# Missing administrator settings preserve access for existing module users.
# readonly defaults to false; true blocks changes, consoles and terminals.
sub new
{
my ($class, $acl, $readonly) = @_;
# Assignments accept complete UUIDs only; names and wildcard entries grant nothing.
my %vms = map { lc($_) => 1 } grep {
	/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i
	} split(/\s+/, $acl->{'vms'} || '');
# Only an explicit 1 enables a delegated grant; omitted grants stay disabled.
return bless { admin => !defined($acl->{'admin'}) || $acl->{'admin'} eq '1',
	readonly => $readonly ? 1 : 0, vms => \%vms,
	grants => { map { $_ => ($acl->{$_} || '') eq '1' ? 1 : 0 }
		qw(power force console terminal password) } }, $class;
}

1;
