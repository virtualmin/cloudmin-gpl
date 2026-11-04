use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore;
use Test::More;
our (%config, %text, %access, $root_directory, $remote_user);
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

# GPL advertises guest keys without touching the Pro library or guest agent.
{
 no warnings qw(redefine once);
 # has_ssh_key_manager() forces GPL behavior regardless of installed files.
 local *main::has_ssh_key_manager = sub { 0 };
 # guest_ssh_service(id) rejects accidental guest access from a preview.
 local *main::guest_ssh_service = sub { die "Preview queried the guest agent" };
 # get_ssh_key_manager() rejects accidental library access from a preview.
 local *main::get_ssh_key_manager = sub { die "Preview opened the Pro library" };
 local %access = (admin => 1);
 local $config{'hide_pro_tips'} = 0;
 my $vm = {uuid => 'fixture', cloudmin => {username => '"><unsafe>'}};
 my $page = show_vm_access($vm, 'password-token', {vm_access_tabs => 'ssh_keys'});
 like($page, qr/name="vm_access_tabs"[^>]*value="ssh_keys"/, 'GPL can select the SSH Keys subtab');
 like($page, qr/Save reusable SSH keys.*?Cloudmin Pro/s, 'SSH Keys explains its Pro requirement');
 like($page, qr/name="action"[^>]*value="reset_password"/, 'GPL keeps the password reset form');
 # Preview selectors retain the compact Pro layout and escape guest metadata.
 my $preview = show_guest_ssh_preview($vm);
 like($preview, qr/<select(?=[^>]*name="username")(?=[^>]*disabled)[^>]*>/,
  'GPL uses a disabled select even for a single preview account');
 unlike($preview, qr/<input[^>]*name="username"/, 'GPL never previews a username text field');
 like($preview, qr/&quot;&gt;&lt;unsafe&gt;/, 'preview escapes the recorded guest username');
 like($preview, qr/\bvalue="&quot;><unsafe>"/, 'select keeps guest metadata inside its quoted value');
 # The library preview follows the empty Saved Keys page, not the add form.
 my $library = show_ssh_library_preview();
 foreach my $label (qw(keys_intro keys_saved keys_none keys_none_desc)) {
  like(html_strip($library), qr/\Q$text{$label}\E/, "library preview includes $label");
 }
 like($library, qr/ui_card_actions.*?<button(?=[^>]*disabled)(?=[^>]*ui_action_normal)[^>]*>.*?Add SSH Key/s,
  'library preview keeps the normal-sized disabled add action in the card header');
 unlike($library, qr/<input|<select|<textarea|list_keys\.cgi/,
  'library preview has no obsolete creation fields or active Pro page links');
 # Both previews advertise the feature without submitting any operation.
 foreach my $html ($preview, $library) {
  like($html, qr/<fieldset\b(?=[^>]*disabled)(?=[^>]*data-pro-disabled="ssh-keys-elem")/,
   'SSH preview disables and mutes all controls');
  like($html, qr/professional-features\/\#ssh-keys/, 'SSH preview links to Pro details');
  unlike($html, qr/<form\b|name="token"|name="action"/, 'preview has no form, token or action');
  unlike($html, qr/<button\b(?![^>]*disabled)[^>]*>/, 'all preview buttons are disabled');
 }
 # Hiding tips removes only the preview, including a saved SSH tab selection.
 local $config{'hide_pro_tips'} = 1;
 $page = show_vm_access($vm, 'password-token', {vm_access_tabs => 'ssh_keys'});
 unlike($page, qr/tab_ssh_keys|data-pro-disabled/, 'hidden Pro tips omit the SSH preview');
 like($page, qr/name="vm_access_tabs"[^>]*value="password"/, 'hidden preview falls back to Password');
 # Password delegates get no host key-management advertisement.
 local $config{'hide_pro_tips'} = 0;
 local %access = (admin => 0, password => 1, vms => 'fixture');
 unlike(show_vm_access($vm, 'password-token', {}), qr/tab_ssh_keys|data-pro-disabled/,
  'delegated users do not see the SSH key preview');
}

done_testing();
