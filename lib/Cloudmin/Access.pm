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

# allows(self, action, [uuid]) checks a known permission and exact VM assignment.
# Read-only administrators can view host inventory but cannot make changes.
# Delegated VM permissions require uuid; administrators need no assignment.
sub allows
{
my ($self, $action, $id) = @_;
# Host inventory and host changes have separate read-only rules.
return $self->{'admin'} ? 1 : 0 if ($action eq 'host');
# Recovery finishes already accepted work and retains normal administrator ACLs.
return $self->{'admin'} && !$self->{'readonly'} ? 1 : 0
	if ($action eq 'recover');
return $self->{'admin'} && !$self->{'readonly'} ? 1 : 0
	if ($action eq 'manage');
# Unknown actions are denied for everyone, including administrators.
return 0 if ($action !~ /\A(?:view|power|force|console|terminal|password)\z/);
# Each delegated operation requires an assignment, regardless of its grant.
my $visible = $self->{'admin'} || (defined($id) && !ref($id) &&
	$self->{'vms'}->{lc($id)});
return 0 if (!$visible);
# Assignment alone allows viewing; changes and connections need explicit grants.
return 1 if ($action eq 'view');
return !$self->{'readonly'} && ($self->{'admin'} ||
	$self->{'grants'}->{$action}) ? 1 : 0;
}

1;
