use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use WebminCore;

# Use the real page helpers and translations without loading host configuration.
our (%text, %config, $root_directory);
our $module_root_directory = "$Bin/..";
$root_directory = $CloudminTest::webmin_root;
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) { chomp; $text{$1} = $2 if /^([^=]+)=(.*)$/; }
close($lang);
require "$Bin/../cloudmin-pages.pl";

# Captures are local copies, so they have no supplied publisher checksum.
my $captured = {id=>'capture', source=>'vm', prepared_vm=>1, state=>'ready',
    name=>'Saved <guest>', pool=>'pool', volume=>'saved.qcow2',
    pool_name=>'default', format=>'qcow2', virtual_size=>20*1024**3};
is(get_image_job_status($captured)->{checksum}, 'Not applicable (local capture)',
    'captured image does not claim a missing or passed publisher checksum');
is(get_image_job_status({%$captured,source=>'local'})->{checksum}, 'Not verified',
    'ordinary imports still report missing verification');
is(get_image_job_status({%$captured,source=>'download',verified=>'sha256'})->{checksum}, 'Passed',
    'download verification keeps its recorded result');

# Creation and template forms share one grouped picker; retain native escaping.
my $choices = get_vm_image_choices([
    $captured, {%$captured,id=>'import',source=>'local',name=>'Uploaded disk'},
    {id=>'catalogue:debian13',catalogue_id=>'debian13',name=>'Debian 13',os=>'Debian'}]);
is_deeply([map { $_->[0] } @$choices], ['catalogue:debian13','import','capture'],
    'catalogue, imports and captures stay in separate groups');
is_deeply([map { $_->[3] } @$choices], ['Debian','Imported images','Captured from virtual machines'],
    'captured images have their own heading');
my $html = show_image_select('image','capture',$choices);
like($html,qr/label="Captured from virtual machines"[^>]*>.*value="capture" selected/s,
    'a captured image stays selectable in its group');
like($html,qr/Saved &lt;guest&gt;/,'captured image names are escaped');
like($html,qr/data-vm-image-source="cloud"/,'capture retains cloud-image filtering');

# The saved-image table explains the local origin as well as the checksum cell.
my $page = show_images_page({jobs=>[$captured], images=>[], pools=>[], readonly=>1});
like($page,qr/Captured from a virtual machine/,'Image Manager identifies the capture origin');
like($page,qr/Not applicable \(local capture\)/,'Image Manager shows the local checksum label');

done_testing();
