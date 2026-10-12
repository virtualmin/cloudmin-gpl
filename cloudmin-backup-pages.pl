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

# parse_backup_target(input, prefix) reads only the currently selected provider.
sub parse_backup_target
{
my ($in, $prefix) = @_;
my $mode = $in->{$prefix.'_mode'} || '';
my $target = {mode => $mode, map { $_ => $in->{$prefix.'_'.$mode.'_'.$_} // '' }
	qw(path host port user password key_file bucket access secret session_token endpoint region ca_file account subscription project refresh_token
	password_clear secret_clear session_token_clear refresh_token_clear)};
foreach my $field (qw(port region endpoint ca_file)) {
	# Disabled controls may still be submitted by themes; honor the default choice.
	$target->{$field} = '' if ($in->{$prefix.'_'.$mode.'_'.$field.'_def'});
}
# Read only the selected SSH authentication method.
if ($mode eq 'ssh') {
	my $auth = $in->{$prefix.'_ssh_authentication'} || 'password';
	die "Select password or private key authentication\n" if ($auth !~ /\A(?:password|key)\z/);
	if ($auth eq 'key') {
		# Do not retain an old saved password when changing to a private key.
		$target->{'password'} = ''; $target->{'password_clear'} = 1;
		$target->{'user'} ||= 'root';
	}
	# Password login must not accidentally use a hidden, previously selected
	# key.
	else {
		$target->{'key_file'} = '';
	}
}
return $target;
}

# show_backup_time(schedule) shows only the fields for the selected recurrence.
sub show_backup_time
{
my ($s) = @_;
my @options;
foreach my $frequency (qw(hourly daily weekly monthly yearly)) {
	my $prefix = 'schedule_'.$frequency.'_';
	my @fields;
	# Calendar fields precede the time, with no day selector for hourly or daily.
	foreach my $field ($frequency eq 'weekly' ? ('weekday') : (),
		$frequency eq 'yearly' ? ('month') : (),
		$frequency eq 'monthly' || $frequency eq 'yearly' ? ('day') : ()) {
		my @choices = $field eq 'weekday' ? map {[$_, $text{'backup_day_'.$_}]} 0..6 :
			$field eq 'month' ? map {[$_, $text{'backup_month_'.$_}]} 1..12 : map {[$_, $_]} 1..31;
		push(@fields, [undef, ui_field($text{'backup_'.$field}, ui_select($prefix.$field, $s->{$field}, \@choices),
			{for => $prefix.$field})]);
	}
	# Hourly runs need only minutes; other recurrences share the hour/minute
	# row.
	my $minute = ui_select($prefix.'minute', $s->{'minute'}, [map {[$_,sprintf('%02d',$_)]} 0..59],
		undef, undef, undef, undef, 'aria-label="'.quote_escape($text{'backup_minute'}).'"');
	my $time = $frequency eq 'hourly' ? $minute : ui_cluster([ui_select($prefix.'hour', $s->{'hour'},
		[map {[$_,sprintf('%02d',$_)]} 0..23], undef, undef, undef, undef,
		'aria-label="'.quote_escape($text{'backup_hour'}).'"'), ':', $minute], {gap => '0.4em'});
	push(@fields, [undef, ui_field($text{$frequency eq 'hourly' ? 'backup_minute' : 'backup_time'}, $time,
		{for => $prefix.($frequency eq 'hourly' ? 'minute' : 'hour')})]);
	push(@options, {value => $frequency, label => $text{'backup_'.$frequency}, fields => \@fields});
}
return ui_select_switch('frequency', $s->{'frequency'}, \@options, {class => 'cloudmin-backup-schedule'}).
	ui_tag('style', '.cloudmin-backup-schedule [data-ui-switch-value] { border: 0; padding: 0; }');
}

1;
