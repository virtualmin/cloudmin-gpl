# Per-user navigation preferences for host inventory pages.
use strict;
use warnings;
our (%config, %text, $remote_user, $module_var_directory,
     $module_root_directory);

# inventory_tabs(page) returns native tab IDs for images, networks or storage.
# The first ID is the page's default tab.
sub inventory_tabs
{
my ($page) = @_;
my %tabs =
	(
		images => [ qw(images add catalogue) ],
		networks => [ qw(net_overview net_networks net_bridges net_interfaces) ],
		storage => [ qw(storage_overview storage_pools storage_volumes) ],
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
read_file("$module_var_directory/inventory-tabs-".urlize($remote_user),
	  \%saved);
return (grep { $_ eq ($saved{$page} || '') } @tabs) ? $saved{$page} : $tabs[0];
}

# save_inventory_tab(page, tab) saves only the caller's validated choice. The
# endpoint verifies the signed POST before calling this function.
sub save_inventory_tab
{
my ($page, $tab) = @_;
require_access('host');
# Saving navigation preferences requires write access.
die "Navigation preferences are disabled in read-only mode\n"
	if (is_readonly_mode());
my @tabs = inventory_tabs($page);
# Accept only IDs belonging to this inventory's native widget.
die "Invalid inventory tab\n" if (!defined($tab) || !grep { $_ eq $tab } @tabs);
# Ignore late browser saves after an administrator disables memory.
return if (($config{$page.'_remember'} // 1) ne '1');
# Derive the private filename from the current login, never from request input.
my $file = "$module_var_directory/inventory-tabs-".urlize($remote_user);
# Convert Webmin file errors to exceptions so the endpoint can report failure.
local $main::error_must_die = 1;
my ($locked, $old_umask);
my $ok = eval {
	# Navigation choices do not belong in file-change or undo logs.
	$locked = lock_file($file, 0, 0, 1);
	# Failed or nested locking must neither write nor release another lock.
	die "Cannot lock saved inventory tabs: $!\n" if (!$locked);
	# Preserve this user's choices for the other inventory pages.
	my %saved;
	read_file($file, \%saved);
	# Avoid repeated writes from reloads and polling-driven redraws.
	if (($saved{$page} || '') ne $tab) {
		$saved{$page} = $tab;
		# Protect new and existing preference files.
		$old_umask = umask(0077);
		write_file($file, \%saved);
		chmod(0600, $file) ||
			die "Cannot protect saved inventory tabs: $!\n";
		}
	1;
	};
# Restore process state and release our lock before propagating any failure.
my $error = $@;
umask($old_umask) if (defined($old_umask));
unlock_file($file) if ($locked);
die $error if (!$ok);
}

# inventory_tab_script(page, [token]) attaches persistence to the native widget.
# Without a write token or enabled memory, the page has no preference writer.
sub inventory_tab_script
{
my ($page, $token) = @_;
# Read-only pages and disabled memory need neither a token nor a browser writer.
return '' if (!$token || ($config{$page.'_remember'} // 1) ne '1');
# Supply allowed IDs and a signed request token; save failures stay inline.
my $data = { page => $page, tabs => [ inventory_tabs($page) ], token => $token,
	     url => get_webprefix().'/server-manager/save_inventory_tab.cgi' };
return ui_tag('span', '',
	      { 'data-inventory-tabs' => convert_to_json($data),
		hidden => undef }).
       ui_tag('span', html_escape($text{'inventory_tab_save_error'}),
	      { 'data-inventory-tabs-error' => $page, hidden => undef, role =>
									       'status' }).
       ui_tag('script', '',
	      { src => get_webprefix().'/server-manager/inventory-tabs.js?'.
		       ((stat("$module_root_directory/inventory-tabs.js"))[
			       9] ||
			0) });
}

1;
