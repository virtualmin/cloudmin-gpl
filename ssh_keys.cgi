#!/usr/local/bin/perl
# The GPL menu opens a preview; upgraded hosts go to the Pro library.
use strict;
use warnings;
our %text;
require './server-manager-lib.pl';
error_setup($text{'keys_error'});
# The library and its preview both require host access.
error($text{'acl_denied'}) if (!can_access('host'));
# Installed Pro remains accessible even when advertisements are hidden.
if (has_ssh_key_manager()) {
    redirect('pro/list_keys.cgi');
    exit;
}
# Apply the preview preference to direct requests as well as the menu.
error($text{'acl_denied'}) if (!show_pro_features());
ui_print_header(undef, $text{'keys_title'}, '', 'ssh_keys');
print show_ssh_library_preview();
ui_print_footer('index.cgi', $text{'vm_return'});
