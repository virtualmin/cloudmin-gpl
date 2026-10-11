# Shared display labels; storage identities and filenames remain unchanged.
use strict;
use warnings;
use Digest::SHA ();
use Encode ();
our %text;

# vm_disk_label(disk)
# Names attached disks by their known role, retaining the guest device name.
sub vm_disk_label
{
my ($disk) = @_;
my $role = $disk->{'role'} || (($disk->{'device'} || '') eq 'cdrom' ? 'cdrom' : 'disk');
return ($text{'vm_disk_role_'.$role} || $text{'vm_disk_role_disk'}).
	($disk->{'target'} ? ' ('.$disk->{'target'}.')' : '');
}

1;
