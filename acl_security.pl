use strict;
use warnings;
require 'server-manager-lib.pl';
our (%in, %text);

# acl_security_noconfig() hides Webmin's separate module-configuration checkbox.
# The save hook derives noconfig from the host administrator role instead.

sub acl_security_noconfig
{
return 1;
}

# acl_security_form(options) displays host access, VM assignments and grants.
# options contains the user's or group's current module ACL.

sub acl_security_form
{
my ($o) = @_;
# Preserve the administrator default used by existing module users.
print ui_table_row($text{'acl_admin'}, ui_yesno_radio('admin',
						      !defined($o->{'admin'}) || $o->{'admin'} eq '1'), 3);
print ui_table_hr();
print ui_table_span(ui_note($text{'acl_scope_note'}));
my @selected = split(/\s+/, $o->{'vms'} || '');
# Webmin checks permission to edit ACLs before calling this hook. List all VMs
# here, including those the editing user cannot access through Cloudmin.
my $servers = eval { get_libvirt()->list_domains() } || [ ];
my @servers = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @$servers;
my %known = map { lc($_->{'uuid'}) => 1 } @servers;
# The shared multi-select widget escapes choice labels itself.
my @choices = map { [ $_->{'uuid'}, $_->{'name'} ] } @servers;
# Retain assignments to temporarily unavailable VMs when editing other grants.
push(@choices, map { [ $_, $_ ] } grep { !$known{lc($_)} } @selected);
print ui_table_row($text{'acl_vms'},
		   ui_multi_select_list('vms', \@selected, \@choices,
					{ empty_label => $text{'index_none'} }),
		   3);
# VM assignments permit viewing; each additional capability is independent.
foreach my $grant (qw(power force console terminal password)) {
	print ui_table_row($text{'acl_'.$grant},
			   ui_yesno_radio($grant, ($o->{$grant} || '') eq '1'),
			   3);
	}
}

# acl_security_save(options) validates grants and VM UUIDs from Webmin's %in.
# Updates options in place; Webmin saves it after this returns.

sub acl_security_save
{
my ($o) = @_;
# Missing fields grant no access, including the administrator field.
$o->{'admin'} = ($in{'admin'} || '') eq '1' ? 1 : 0;
# Accept joined form values, rejecting names and wildcard assignments.
my @vms = grep { length } split(/[\s\0]+/, $in{'vms'} || '');
error($text{'acl_invalid_vm'}) if (grep {
	!/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i } @vms);
# Lowercase and deduplicate UUIDs before saving assignments.
my %seen;
$o->{'vms'} = join(' ', grep { !$seen{$_}++ } map { lc } @vms);
# Save each grant independently; unchecked or omitted fields revoke it.
foreach my $grant (qw(power force console terminal password)) {
	$o->{$grant} = ($in{$grant} || '') eq '1' ? 1 : 0;
	}
# Derive noconfig from the role, regardless of any submitted value.
$o->{'noconfig'} = $o->{'admin'} ? 0 : 1;
}

1;
