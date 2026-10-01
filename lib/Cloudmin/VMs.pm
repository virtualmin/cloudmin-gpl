package Cloudmin::VMs;

# VM creation policy and orchestration shared by the UI and controller API.
use strict;
use warnings;
use WebminCore qw(convert_to_json make_dir
	check_ipaddress check_ip6address);
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(decode_base64);
use Socket qw(AF_INET AF_INET6 inet_pton inet_ntop);
use POSIX qw(ceil);
use File::Basename qw(dirname);
require(dirname(__FILE__).'/Images.pm');
require(dirname(__FILE__).'/Worker.pm');
require(dirname(__FILE__).'/Software.pm');
require(dirname(__FILE__).'/NetworkPreflight.pm');

# image_metadata(self, image)
# Fills missing metadata from the exact downloaded catalogue asset, not its
# name.
sub image_metadata
{
my ($self, $image) = @_;
if (!$image->{'architecture'} && ($image->{'source'} || '') eq 'download') {
	# One catalogue ID can identify different architectures and different
	# files.
	my ($entry) = grep { $_->{'id'} eq ($image->{'slug'} || '') &&
		$_->{'url'} eq ($image->{'url'} || '') && $_->{'format'}
		eq $image->{'format'} }
		@{$self->{'catalogue'}->list_entries()};
	# Use catalogue metadata only when ID, URL and disk format all
	# match.
	return $entry if ($entry);
	}
return $image;
}

1;
