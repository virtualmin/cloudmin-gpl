# Networking pages use Webmin's native widgets.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Share column selection and timeout defaults with the configuration editor.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-config-lib.pl'));
our (%text);

# network_form(action, token, [fields])
# Starts an independent POST form that returns to the relevant inventory tab.
sub network_form
{
my ($action, $token, $fields) = @_;
my %values = (%{$fields || {}});
$values{'tab'} ||= $action =~ /\A(?:bridge|confirm|rollback)/ ? 'bridges' : 'networks';
return ui_form_start('networks.cgi', 'post').ui_hidden('action', $action).
	ui_hidden('token', $token).join('', map { ui_hidden($_, $values{$_}) } sort keys %values);
}

# network_values(values, [empty])
# Keeps addresses on separate lines, wrapping long IPv6 values only when needed.
sub network_values
{
my ($values, $empty) = @_;
return ui_tag('span', html_escape($empty || $text{'net_none'}),
	{ class => 'cloudmin-network-muted' }) if (!@$values);
return join('', map { ui_tag('span', html_escape($_),
	{ class => 'cloudmin-network-value' }) } @$values);
}

1;
