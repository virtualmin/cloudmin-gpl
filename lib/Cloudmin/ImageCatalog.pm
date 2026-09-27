package Cloudmin::ImageCatalog;

# Validated access to Cloudmin and custom virtual-machine image catalogues.
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();
use Time::Local qw(timegm);
use WebminCore qw(read_file_contents write_file_contents convert_from_json
	convert_to_json);
require(dirname(__FILE__).'/Images.pm');
require(Cwd::abs_path(dirname(__FILE__).'/ImageChoices.pm'));

# normalize_architecture([architecture])
# Converts common architecture aliases to libvirt and distribution names.
# Omitted input becomes an empty filter; unknown names are lowercased and
# trimmed.
sub normalize_architecture
{
my ($architecture) = @_;
$architecture = lc($architecture || '');
$architecture =~ s/^\s+|\s+$//g;
# Collapse the distribution/vendor spellings used for the same CPU family.
return 'x86_64' if ($architecture =~ /^(?:amd64|x86-64|x86_64)$/);
# Debian's arm64 and libvirt's aarch64 refer to the same 64-bit family.
return 'aarch64' if ($architecture =~ /^(?:arm64|aarch64)$/);
# Keep 32-bit ARM aliases distinct from ARM64 assets.
return 'armv7l' if ($architecture =~ /^(?:arm|armhf|armv7|armv7l)$/);
return $architecture;
}

1;
