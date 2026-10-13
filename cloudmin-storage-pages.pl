# Storage pages use the same native tabs and compact cards as Networking.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Share visible-column definitions with the module configuration editor.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-config-lib.pl'));
our %text;

# storage_form(action, token, [fields], [tab])
# Keeps each action in its own POST form, outside other forms.
sub storage_form
{
my ($action, $token, $fields, $tab) = @_;
return ui_form_start('storage.cgi', 'post').ui_hidden('action', $action).
	ui_hidden('token', $token).ui_hidden('tab', $tab || 'pools').
	join('', map { ui_hidden($_, $fields->{$_}) } sort keys %{$fields || {}});
}

1;
