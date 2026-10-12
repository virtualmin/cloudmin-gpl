use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Use the same column and section definitions as Module Configuration.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-config-lib.pl'));
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-pro-lib.pl'));
our (%text, $remote_user, $module_root_directory);

# show_backup_input(prefix, mode, field, [value]) renders a sized destination input.
# Optional connection settings use the standard default/custom radio controls.
sub show_backup_input
{
my ($prefix, $mode, $field, $value) = @_;
my $name = $prefix.'_'.$mode.'_'.$field;
my %sizes = (host => 25, port => 5, user => 25, password => 25,
	key_file => 25, region => 18, bucket => 25, account => 25, project => 25);
my $size = $sizes{$field} || 40;
my $hint = $field eq 'user' || $field eq 'password'
	? 'placeholder="'.quote_escape($text{'backup_field_'.$field}).'" aria-label="'.quote_escape($text{'backup_field_'.$field}).'"'
	: $field eq 'session_token' ? 'placeholder="'.quote_escape($text{'backup_optional'}).'"' : '';
my %defaults = (port => '22', region => 'us-east-1', endpoint => '', ca_file => '');
# Default/custom choices prevent hidden custom values overriding defaults.
if (exists($defaults{$field})) {
	return ui_opt_textbox($name, ($value // '') eq $defaults{$field} ? '' : $value,
		$size, $text{'backup_default_'.$field}, $text{'backup_custom'});
}
if ($field eq 'key_file' || ($field eq 'path' && $mode eq 'local')) {
	# These paths belong to this host, so offer Webmin's file chooser.
	return ui_filebox($name, $value, $size, undef, undef, undef, $field eq 'path');
}
if ($field =~ /\A(?:password|secret|session_token|refresh_token)\z/) {
	# Never echo saved credentials or offer password generation for remote logins.
	my $input = ui_password($name, '', $size, 0, undef,
		'autocomplete="new-password" data-password-meter-skip '.$hint);
	# Offer explicit clearing only when there is a saved secret to replace.
	$input .= ui_note($text{'backup_keep_secret'}, 0).
		ui_checkbox($name.'_clear', 1, $text{'backup_clear_secret'}, 0) if (length($value || ''));
	return $input;
}
return ui_textbox($name, $value, $size, undef, undef, $hint);
}

1;
