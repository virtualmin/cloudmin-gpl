# Cloudmin navigation uses the same selected-server layout as Virtualmin.
use strict;
use warnings;
use WebminCore;
our ($module_root_directory);
init_config();
require "$module_root_directory/server-manager-lib.pl";

# list_webmin_menu([data], [input])
# Resolves the current guest from the theme or URL, retaining global links
# when libvirt is unavailable or no virtual machines exist. Missing theme
# data and request input default to empty hashes.
sub list_webmin_menu
{
my ($data, $input) = @_;
$data ||= {};
$input ||= {};
my @servers = list_managed_servers_sorted();
# Global pages also use id for images and jobs; those must not select a VM.
my ($linked) = grep { $_->{'uuid'} eq ($input->{'id'} || '') } @servers;
my $selected = $input->{'sid'} || ($linked && $linked->{'uuid'}) ||
	$data->{'server'};
return get_menu_items(\@servers, $selected,
	is_readonly_mode(), foreign_check('xterm'),
	foreign_available('webminlog'));
}

1;
