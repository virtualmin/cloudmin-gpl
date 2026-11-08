# Shared display labels; storage identities and filenames remain unchanged.
use strict;
use warnings;
use Digest::SHA ();
use Encode ();
our %text;

# vm_disk_label(disk) Names attached disks by their known role, retaining
# the guest device name.
sub vm_disk_label
{
my ($disk) = @_;
my $role = $disk->{'role'} || (($disk->{'device'} || '') eq 'cdrom'
	? 'cdrom'
	: 'disk');
return ($text{'vm_disk_role_'.$role} || $text{'vm_disk_role_disk'}).
       ($disk->{'target'} ? ' ('.$disk->{'target'}.')' : '');
}

# storage_volume_label(volume) Shortens generated filenames for display; custom
# volume names stay intact.
sub storage_volume_label
{
my ($volume) = @_;
my $name = $volume->{'name'} || '';
my ($guest, $role, $target);
if (
	$name =~ /\Acloudmin-(.+)-(system|data|seed)-([a-f0-9]{32})\.(?:qcow2|iso|[0-9]+)\z/) {
	# Current names retain the original guest name after a disk is detached.
	($guest, $role) = ( $1, $2 );
	}
elsif (
	$name =~ /\Acloudmin-(vm|disk|seed)-([a-f0-9]{32})\.(?:qcow2|iso|[0-9]+)\z/) {
	# Older generated names contain a role and creation
	# ID but no guest name.
	$role = $1 eq 'vm' ? 'system' : $1 eq 'disk' ? 'data' : 'seed';
	}
elsif (
	$name =~ /\Acloudmin-snapshot-([a-f0-9]{32})-([a-z]+[0-9]*)\.(qcow2|[0-9]+)\z/) {
	# Keep the disk target and a short reference to
	# distinguish snapshot layers.
	$target = $2;
	$role = $3 eq 'qcow2' ? 'snapshot' : 'restored';
	}
elsif ($name =~ /\Acloudmin-(.+)-[a-f0-9]{32}\.(?:qcow2|raw)\z/) {
	# Imported images use their catalogue slug when no
	# saved name is available.
	($guest, $role) = ( $1, 'image' );
	my ($image) =
		grep { $_->{'kind'} eq 'image' } @{($volume->{'usage'} ||
						    { })->{'owners'} || [ ]};
	$guest = $image->{'name'} if ($image && length($image->{'name'} || ''));
	}
else {
	# Administrator-chosen filenames are already meaningful identifiers.
	return $name;
	}
my $label = $text{'vm_disk_role_'.$role};
$label .= ' ('.$target.')' if ($target);
$label = $guest.' - '.$label if ($guest);
# Include the complete filename in the reference: repeated snapshot restores can
# share a creation ID but refer to different files.
my $reference =
	substr(Digest::SHA::sha256_hex(Encode::encode_utf8($name)), 0, 8);
return $label.' ('.$reference.')';
}

1;
