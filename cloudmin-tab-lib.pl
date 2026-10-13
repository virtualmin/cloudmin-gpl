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

# inventory_tab(page, [explicit]) selects a permitted saved tab or the default.
# A valid explicit native tab ID wins; an invalid one selects the default.
# Without an explicit tab, enabled memory restores the caller's saved choice.
sub inventory_tab
{
my ($page, $explicit) = @_;
require_access('host');
my @tabs = inventory_tabs($page);
# Explicit links must not be redirected to a previously visited tab.
return (grep { $_ eq $explicit } @tabs) ? $explicit : $tabs[0]
	if (defined($explicit) && length($explicit));
# Disabling memory leaves saved choices intact for later use.
return $tabs[0] if (($config{$page.'_remember'} // 1) ne '1');
# Read-only host administrators may still read their own valid saved choice.
my %saved;
read_file("$module_var_directory/inventory-tabs-".urlize($remote_user), \%saved);
return (grep { $_ eq ($saved{$page} || '') } @tabs) ? $saved{$page} : $tabs[0];
}

1;
