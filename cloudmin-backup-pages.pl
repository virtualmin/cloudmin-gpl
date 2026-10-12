use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Use the same column and section definitions as Module Configuration.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-config-lib.pl'));
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-pro-lib.pl'));
our (%text, $remote_user, $module_root_directory);

# show_backup_destination(prefix, [target]) groups fields by destination provider.
# prefix separates each selector's input names. target defaults to local backups
# under /var/backups/cloudmin; saved secrets are never echoed into the form.
sub show_backup_destination
{
my ($prefix, $target) = @_;
$target ||= {mode => 'local', path => '/var/backups/cloudmin'};
my @options;
# Offer disabled Pro previews when enabled. Always retain a saved unavailable
# provider so editing its schedule cannot silently select a different target.
my %installed = map { $_ => 1 } Cloudmin::BackupTransport::modes();
my @preview = grep { !$installed{$_} && (show_pro_features() || $target->{'mode'} eq $_) }
	qw(gcs azure bb dropbox drive);
foreach my $mode (Cloudmin::BackupTransport::modes(), @preview) {
	my $preview = !$installed{$mode};
	my @fields = $mode eq 'local' ? qw(path) : $mode eq 'ssh' ? qw(host port path authentication) :
		$mode eq 's3' ? qw(bucket path access secret session_token region endpoint ca_file) :
		$mode eq 'azure' ? qw(bucket path account subscription secret) :
		$mode eq 'bb' ? qw(bucket path access secret) :
		$mode eq 'gcs' ? qw(bucket path project access secret refresh_token) : qw(path project access secret refresh_token);
	my @inputs;
	foreach my $field (@fields) {
		# Each selector has distinct field names; hidden providers cannot override it.
		my $name = $prefix.'_'.$mode.'_'.$field;
		my $value = $target->{'mode'} eq $mode ? $target->{$field} : '';
		my $input;
		if ($field eq 'authentication') {
			# Show one credential method; the parser discards the unused method.
			my $ssh = $target->{'mode'} eq 'ssh' ? $target : {};
			$input = ui_select_switch($name, $ssh->{'key_file'} ? 'key' : 'password', [
				{value => 'password', label => $text{'backup_field_password'}, fields => [
					[undef, show_backup_input($prefix, $mode, 'user', $ssh->{'user'})],
					[undef, show_backup_input($prefix, $mode, 'password', $ssh->{'password'})]]},
				{value => 'key', label => $text{'backup_field_key_file'}, fields => [[undef,
					show_backup_input($prefix, $mode, 'key_file', $ssh->{'key_file'})]]},
			]);
		}
		# Ordinary destination fields share sizing, defaults and secret
		# handling.
		else {
			$input = show_backup_input($prefix, $mode, $field, $value);
		}
		# Keep labels above inputs and disable fields for unavailable providers.
		push(@inputs, [undef, ui_field(undef,
			ui_tag('span', $preview ? pro_feature_preview($input, 'cloud-backups') : $input, {style => 'max-width:100%'}),
			{for => $name, label_html => hlink($text{'backup_field_'.$field}, 'backup_field_'.$field)})]);
	}
	push(@options, {value => $mode, label => $text{'backup_mode_'.$mode}.($preview ? ' (Pro)' : ''), fields => \@inputs});
}
# Stacked labels stay level when the authentication control occupies two lines.
my $switch = ui_select_switch($prefix.'_mode', $target->{'mode'}, \@options,
	{class => 'cloudmin-backup-destination'});
# The common widget has no per-option disabling API; disable only Pro options.
foreach my $mode (@preview) {
	$switch =~ s{(<option\b[^>]*\bvalue=["']\Q$mode\E["'])}{$1 disabled}g;
}
# Explain unavailable destinations only while their previews are present.
return $switch.(@preview ? ui_note($text{'pro_tip_cloud-backups'}.' '.pro_feature_badge('cloud-backups'), 0) : '').
	ui_tag('style', '.cloudmin-backup-destination .ui_select_switch_field { align-items: flex-start; }
		.cloudmin-backup-destination [data-ui-switch-value] { border: 0; padding: 0; }');
}

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
