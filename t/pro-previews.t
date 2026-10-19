use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore;
use Test::More;
our (%config, %text, $root_directory, $remote_user);
our $module_root_directory = "$Bin/..";
$root_directory = $CloudminTest::webmin_root;
$remote_user = 'root';
# Load real labels and renderers so fixtures exercise native Webmin markup.
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) { chomp; $text{$1} = $2 if /^([^=]+)=(.*)$/; }
close($lang);
require "$Bin/../cloudmin-pages.pl";
require "$Bin/../cloudmin-backup-pages.pl";
require "$Bin/../cloudmin-image-pages.pl";
require "$Bin/../lib/Cloudmin/BackupTransport.pm";

# Section renderers expect an enclosing four-column table.
ui_table_start(undef, 'width=100%', 4);

# Rendering stubs affect edition availability only, not save validation.
{
 no warnings 'redefine';
 local *Cloudmin::Software::has_scripts = sub { 0 };
 local *Cloudmin::BackupTransport::has_pro_providers = sub { 0 };
 # GPL script previews use disabled controls and the shared inline Pro label.
 my $form = show_software_settings({});
 unlike($form, qr/Pro Feature/, 'inline script previews omit the page-wide Pro banner');
 is(scalar(() = $form =~ /<fieldset\b(?=[^>]*\bdisabled\b)[^>]*>/g), 2,
  'both script groups are natively disabled');
 like($form, qr/data-pro-disabled="setup-scripts-elem"/, 'preview reuses Virtualmin styling');
 like($form, qr/&#128274;&nbsp;&nbsp;<span[^>]*>Pro<\/span>/,
  'preview uses Virtualmin inline lock and Pro text');
 # Ordinary packages and both Virtualmin editions remain editable in GPL.
 my $packages = show_software_settings({packages=>'jq',software=>'virtualmin-pro'});
 like($packages, qr/<textarea\b(?![^>]*disabled)[^>]*name="packages"/, 'GPL package installation stays editable');
 like($packages, qr/<select\b(?![^>]*disabled)[^>]*name="software"/, 'Virtualmin Pro installer remains selectable in GPL');
 # Preserve and escape old scripts, with clearing restricted to writable users.
 my $saved = show_software_settings({before_script=>'echo <saved>', after_script=>'true'});
 like($saved, qr/echo &lt;saved&gt;/, 'saved script is escaped and readable');
 like($saved, qr/name="clear_setup_scripts"/, 'GPL offers explicit clearing');
 unlike(show_software_settings({before_script=>'true'},1), qr/<input\b(?![^>]*disabled)[^>]*name="clear_setup_scripts"/,
  'read-only users cannot clear scripts');
 # Hidden advertisements must not hide saved settings or prevent clearing.
 local $config{'hide_pro_tips'} = 1;
 unlike(show_software_settings({}), qr/data-pro|before_script|after_script|Pro Feature/,
  'administrator can hide fresh script previews');
 like(show_software_settings({before_script=>'saved'}), qr/name="clear_setup_scripts"/,
  'hidden advertisements do not hide saved script data or its clearing action');
 unlike(show_backup_destination('dest'), qr/value="(?:gcs|azure|bb|drive|dropbox)"/,
  'advertising preference hides unavailable cloud destinations');
 like(show_backup_destination('dest',{mode=>'gcs',path=>'saved'}), qr/<option\b(?=[^>]*value="gcs")(?=[^>]*selected)(?=[^>]*disabled)/,
  'saved unavailable destination stays selected instead of silently becoming local');
}
# Advertising preferences never disable an installed Pro implementation.
{
 no warnings 'redefine';
 local *Cloudmin::Software::has_scripts = sub { 1 };
 local $config{'hide_pro_tips'} = 1;
 my $form = show_software_settings({before_script=>'true'});
 unlike($form, qr/data-pro-disabled|Pro Feature|clear_setup_scripts/, 'installed Pro has ordinary active controls');
 like($form, qr/<input\b(?![^>]*disabled)[^>]*name="before_script_mode"/, 'Pro script choices are enabled');
}
# The shared capture form is usable in Pro and never submits from its GPL preview.
my $source = {name=>'Example',id=>'fixture',revision=>'revision',
 options=>{pools=>[{id=>'pool',name=>'Default'}]},disks=>[{bytes=>1024**3}]};
my $preview = show_vm_image_form($source, '', 1);
like($preview, qr/<fieldset\b(?=[^>]*disabled)(?=[^>]*data-pro-disabled="image-capture-elem")/, 'capture preview disables all inputs');
like($preview, qr/<input\b(?=[^>]*type=['"]submit['"])(?=[^>]*disabled)/, 'capture preview disables submission');
unlike(show_vm_image_form($source,'token'), qr/<(?:input|select|textarea|button|fieldset)\b[^>]*\bdisabled[=\s>]|data-pro-disabled/, 'Pro capture remains enabled');

# Field names must be visible text, with links to their full help pages.
foreach my $disabled (0, 1) {
 my $form = show_vm_image_form($source, 'token', $disabled);
 foreach my $field ([vm_image_name => 'image_machine_name'],
   [images_storage => 'image_machine_storage'],
   [vm_image_clean_credentials => 'image_machine_identity'],
   [vm_image_preparation => 'image_machine_preparation']) {
  like(html_strip($form), qr/\Q$text{$field->[0]}\E/,
   "$field->[0] is visible in ".($disabled ? 'GPL preview' : 'Pro form'));
  like($form, qr{href=["'][^"']*/help\.cgi/[^"']*/\Q$field->[1]\E["']},
   "$field->[0] links to its help page");
 }
 # Cleanup applies to all accounts by default, with no source-account prompt.
 unlike($form, qr/name="username"/, 'capture does not ask for a source account');
 is(scalar(() = $form =~ /<input\b(?=[^>]*name="clean_credentials")(?=[^>]*type=['"]radio['"])/g),
  2, 'credential cleanup has a Yes/No radio group');
 like($form, qr/<input\b(?=[^>]*name="clean_credentials")(?=[^>]*value="1")(?=[^>]*checked)/,
  'credential cleanup defaults to Yes');
}

done_testing();
