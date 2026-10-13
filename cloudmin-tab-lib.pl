# Per-user navigation preferences for host inventory pages.
use strict;
use warnings;
our (%config, %text, $remote_user, $module_var_directory, $module_root_directory);

# inventory_tabs(page) returns native tab IDs for images, networks or storage.
# The first ID is the page's default tab.
sub inventory_tabs
{
my ($page) = @_;
my %tabs = (
	images => [qw(images add catalogue)],
	networks => [qw(net_overview net_networks net_bridges net_interfaces)],
	storage => [qw(storage_overview storage_pools storage_volumes)],
);
# Reject unknown pages before using them as preference keys.
die "Invalid inventory page\n" if (!defined($page) || !$tabs{$page});
return @{$tabs{$page}};
}

1;
