use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use WebminCore;
our (%text, $root_directory);
$root_directory = $CloudminTest::webmin_root;
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) { chomp; $text{$1} = $2 if /^([^=]+)=(.*)$/; }
close($lang);
$WebminCore::text{'nice_size_MiB'} = 'MiB';
require "$Bin/../cloudmin-pages.pl";
require "$Bin/../cloudmin-storage-pages.pl";
require "$Bin/../lib/Cloudmin/Storage.pm";
# storage_input(html, name)
# Extracts an input without treating angle brackets in quoted values as tags.
sub storage_input
{
	my ($html, $name) = @_;
	return (grep { /\bname=['"]\Q$name\E['"]/ }
		$html =~ /(<input\b(?:[^>"']|"[^"]*"|'[^']*')*>)/g)[0];
}
# The workstation has no live Webmin account; File Manager access is mocked.
{
	no warnings 'redefine';
	*foreign_available = sub { 0 };
}
my $pool = { uuid => '11111111-2222-3333-4444-555555555555', name => 'extra <one>', type => 'dir',
	state => 'running', active => 1, manageable => 1, persistent => 1, autostart => 1,
	revision => 'revision', target => '/storage/<extra>', volume_count => 1, guests => [],
	capacity => 100*1024**2, available => 60*1024**2, allocation => 40*1024**2,
	volumes => [{name => '<disk>', path => '/storage/<extra>/disk', capacity => 1024**2, allocation => 1024}] };
my $data = {local => 1, pools => [$pool]};
$data->{'overview'} = Cloudmin::Storage::overview($data->{'pools'});
my $html = show_storage_page($data, 'token');
like($html, qr/cloudmin_storage_tabs/, 'native tabs rendered');
is(storage_page_tab(''), 'overview', 'overview is the landing tab');
is(storage_page_tab('invalid'), 'overview', 'unrecognized tabs fall back to overview');
like($html, qr/cloudmin-storage-summary/, 'overview summary rendered');
like($html, qr/storage.cgi\?tab=pools(?:&amp;|&)pool=11111111/, 'pool names link to management cards');
like($html, qr/name=['"]tab['"][^>]*value=['"]pools/, 'mutations return to the management tab');
unlike($html, qr/\brequired\b|\bpattern=/, 'creation uses server validation');
{
	# Inner tabs retain their selection without changing the outer inventory tab.
	like(storage_input($html, 'cloudmin_storage_pool_tabs'), qr/value="storage_pool_list"/,
		'existing pools open by default');
	unlike($html, qr/hiddenopener_create_storage|data-name="create_storage"/,
		'creation no longer needs an accordion');
	my $volumes = show_storage_page($data, 'token', 'volumes');
	like($volumes, qr/id='div_storage_volumes' class='opener_shown\b/,
		'inner pool tabs leave the outer volumes tab selected');
	my $failed = show_storage_page($data, 'token', 'pools',
		{action => 'create', name => 'retry'}, 'Invalid directory');
	like(storage_input($failed, 'cloudmin_storage_pool_tabs'), qr/value="storage_pool_create"/,
		'failed creation reopens its tab');
	like($failed, qr/id='div_storage_pools' class='opener_shown\b/,
		'failed creation keeps the outer pools tab visible');
	like(storage_input($failed, 'name'), qr/value="retry"/,
		'failed creation retains its name');
	my $empty = show_storage_page({%$data, pools => []}, 'token', 'pools');
	like(storage_input($empty, 'cloudmin_storage_pool_tabs'), qr/value="storage_pool_list"/,
		'empty storage still opens the list first');
	unlike(show_storage_page($data, ''), qr/name="cloudmin_storage_pool_tabs"/,
		'read-only users have no creation tab');
	unlike(show_storage_page({%$data, local => 0}, 'token'), qr/name="cloudmin_storage_pool_tabs"/,
		'remote connections have no creation tab');
}
{
	my $other = {%$pool, uuid => 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'};
	my $selected = show_storage_page({%$data, pools => [$pool, $other]}, '', 'pools', {}, undef, $other->{'uuid'});
	my ($first) = $selected =~ /(<section\b[^>]*>)/;
	like($first, qr/\bcloudmin-storage-selected\b/, 'selected pool is highlighted');
	like($first, qr/id=['"]cloudmin-pool-aaaaaaaa/, 'selected pool comes first');
}
like($html, qr/Filesystem usage/, 'per-filesystem capacity is labelled');
like($html, qr/ui_progress/, 'capacity is shown as a progress bar');
{
	# Availability excludes reserves, while the bar represents actual used data.
	local $pool->{'available'} = 50*1024**2;
	my $card = show_storage_pool($pool, 'token');
	like($card, qr/Filesystem usage: 40% used/, 'usage label explains the filled bar');
	like($card, qr/50 MiB available of 100 MiB/, 'available space is distinct from total minus used');
	like($card, qr/aria-valuenow="40"/, 'bar uses allocated space without treating reserves as used');
}
like($html, qr/extra &lt;one&gt;/, 'pool name escaped');
like($html, qr{<tt>/storage/&lt;extra&gt;</tt>}, 'storage paths use escaped technical text');
like($html, qr/&lt;disk&gt;/, 'volume name escaped');
my @tags = $html =~ /<([a-z][\w-]*)\b(?:[^>"']|"[^"]*"|'[^']*')*>/gi;
ok(!grep({ $_ eq 'extra' || $_ eq 'disk' } @tags), 'paths and volumes cannot inject markup');
like($html, qr/data-sortable=['"]1/, 'volume table supports theme sorting');
like($html, qr/value=['"]stop['"]/, 'active pool offers stop');
like($html, qr/ui_svg_icon_check/, 'enabled button has an icon');
like($html, qr/vui_ui_block/, 'standard description styling used');
{
	local $pool->{'active'} = 0; local $pool->{'state'} = 'inactive'; local $pool->{'autostart'} = 0;
	$html = show_storage_page($data, 'token');
	like($html, qr/value=['"]start['"]/, 'inactive pool offers start');
	like($html, qr/ui_svg_icon_x/, 'disabled boot button retains icon alignment');
	like($html, qr/Start this pool to view/, 'inactive capacity is unavailable, not zero');
	unlike($html, qr/ui_progress|&lt;disk&gt;/, 'inactive inventory is not presented as live');
}
{
	local $pool->{'guests'} = [{name => 'guest', uuid => 'guest-id'}];
	$html = show_storage_page($data, 'token');
	like($html, qr/Stop the virtual machines using this pool/, 'running users explain unavailable stop control');
	unlike(show_storage_pool($pool, 'token'), qr/machine.cgi/, 'VM identities live in the volume list');
	unlike($html, qr/value=['"]stop['"]/, 'running guests hide stop action');
}
$html = show_storage_page($data, '');
unlike($html, qr/<form\b/, 'read-only inventory contains no mutation forms');
{
	local $pool->{'manageable'} = 0; local $data->{'local'} = 0;
	unlike(show_storage_pool($pool, 'token'), qr/<form\b/, 'unsupported pools have no mutation controls');
	my $inventory = show_storage_volumes([$pool], 'token');
	my $checkbox = storage_input($inventory, 'volume');
	like($checkbox, qr/\bdisabled\b/, 'unsupported volume keeps a disabled checkbox');
	my $button = storage_input($inventory, 'delete');
	like($button, qr/\bdisabled\b/, 'unsupported volumes keep a disabled delete button');
}
$html = show_storage_page($data, 'token', 'invalid', {action => 'create', name => '<retry>', path => '/retry'}, 'failure <reason>');
like($html, qr/failure &lt;reason&gt;/, 'action failure safely displayed');
like($html, qr/value=['"]&lt;retry&gt;/, 'failed creation retains user input');
$html = show_storage_page({error => '<socket failure>'}, 'token');
like($html, qr/&lt;socket failure&gt;/, 'storage failure displayed');
unlike($html, qr/No storage pools|<form\b/, 'inventory failure is not empty inventory or a creation prompt');
{
	# Libvirt diagnostics may contain paths with spaces and markup characters.
	local $data->{'usage_errors'} = ["Cannot check dependencies: no volume at '/storage/<extra>/disk one'"];
	$html = show_storage_page($data, 'token', 'volumes');
	like($html, qr{Deletion is unavailable.*Cannot check dependencies: no volume at &#39;/storage/&lt;extra&gt;/disk one&#39;}s,
		'dependency warning escapes diagnostic text');
}
{
	my $empty = {pools => [], overview => Cloudmin::Storage::overview([])};
	$html = show_storage_page($empty, '');
	like($html, qr/No storage pools found/, 'empty overview offers an understandable state');
	unlike($html, qr/<form\b/, 'empty read-only overview does not offer mutations');
}
{
	no warnings 'redefine';
	local *WebminCore::theme_nice_size = sub { '<span>60 MiB</span>' };
	$html = show_storage_page($data, 'token');
	unlike($html, qr/&lt;span&gt;/, 'theme size markup is stripped for progress labels');
}
# Owners and deletion controls stay specific to each volume and respect access.
{
	my $volume = $pool->{'volumes'}->[0];
	local $volume->{'usage'} = {owners => [], reason => '', checked => 1};
	$html = show_storage_volumes([$pool], 'token');
	like($html, qr/^<form\b/, 'volume inventory starts directly with its native form');
	unlike($html, qr/cloudmin-storage-volumes/, 'volume renderer adds no wrapper');
	like($html, qr/name=['"]volume['"]/, 'unused volume has a selection checkbox');
	my $checkbox = storage_input($html, 'volume');
	unlike($checkbox, qr/\bdisabled\b/, 'unused volume checkbox is enabled');
	my $button = storage_input($html, 'delete');
	unlike($button, qr/\bdisabled\b/, 'unused volume enables deletion review');
	like($html, qr/value=['"]review_volumes['"]/, 'selected volumes go to a separate review');
	unlike($html, qr/value=['"]delete_volumes['"]/, 'inventory cannot delete directly');
	unlike($html, qr/<b>Actions<\/b>/, 'volume table has no per-row actions');
	unlike(show_storage_volumes([$pool], ''), qr/name=['"]volume['"]/, 'read-only users have no selection controls');
	{
		# LVM pools have no lifecycle controls, but their unused volumes are deletable.
		local $pool->{'manageable'} = 0; local $pool->{'volume_manageable'} = 1;
		my $inventory = show_storage_volumes([$pool], 'token');
		unlike(storage_input($inventory, 'volume'), qr/\bdisabled\b/, 'unused LVM volume checkbox is enabled');
		unlike(storage_input($inventory, 'delete'), qr/\bdisabled\b/, 'LVM volumes can enter deletion review');
	}
	for my $reason ('Referenced disk', '') {
		$volume->{'usage'} = {owners => [], reason => $reason, checked => 0};
		$html = show_storage_volumes([$pool], 'token');
		$checkbox = storage_input($html, 'volume');
		like($checkbox, qr/\bdisabled\b/, 'incomplete usage keeps a disabled checkbox');
		$button = storage_input($html, 'delete');
		like($button, qr/\bdisabled\b/, 'incomplete usage disables deletion review');
		}
	$volume->{'usage'} = {owners => [
		{kind => 'vm', uuid => 'guest-id', name => 'stopped <guest>', active => 0},
		{kind => 'image', id => 'image-id', name => 'image <one>'},
	], reason => 'Owned', checked => 1};
	$html = show_storage_volumes([$pool], 'token');
	like($html, qr/machine.cgi\?id=guest/, 'volume links to its VM');
	unlike($html, qr/Stopped|Running/, 'volume inventory omits VM power state');
	unlike(show_storage_volume_usage($volume->{'usage'}), qr/images.cgi|image &lt;one&gt;/, 'Used by contains only actual VM links');
	like(show_storage_volume_type($volume->{'usage'}), qr/<details class="inline inlined"><summary>Imported image<\/summary>.*Virtual machine/, 'multiple types use inline details');
	like($html, qr/stopped &lt;guest&gt;/, 'owner names are escaped');
	$checkbox = storage_input($html, 'volume');
	like($checkbox, qr/\bdisabled\b/, 'owned volumes have disabled checkboxes');
	$button = storage_input($html, 'delete');
	like($button, qr/\bdisabled\b/, 'all-owned inventory keeps a disabled delete button');
	like($html, qr/class=['"]select_all['"]/, 'all-disabled inventory keeps Select all');
	like($html, qr/class=['"]select_invert['"]/, 'all-disabled inventory keeps Invert selection');
	my $confirmation = show_storage_delete_volumes([{%$volume, uuid => $pool->{'uuid'},
		pool => $pool->{'name'}, revision => 'revision'}], 'token');
	like($confirmation, qr/value=['"]delete_volumes['"]/, 'confirmation submits distinct volume action');
	like($confirmation, qr/name=['"]confirm['"]/, 'explicit confirmation required');
	like($confirmation, qr/name=['"]tab['"][^>]*value=['"]volumes/, 'deletion returns to volumes tab');
	like($confirmation, qr/This cannot be undone/, 'irreversible deletion is explained');
	like($confirmation, qr/&lt;disk&gt;/, 'confirmation escapes selected volume');
	unlike($confirmation, qr/\brequired\b/, 'confirmation uses server validation');
}
# The checked table must target its own form after all pool action forms.
{
	local $WebminCore::ui_formcount = 0;
	local $pool->{'volumes'}->[0]->{'usage'} = {owners => [], checked => 1};
	$html = show_storage_page($data, 'token');
	my ($table) = $html =~ /(<div[^>]*id="cloudmin-storage-volumes".*)/s;
	like($table, qr/\A<div[^>]*data-storage-tab="volumes"/, 'volume selectors use the existing tab');
	like($table, qr/document.forms\[3\]/, 'select-all targets volumes after the three pool forms');
	my $usage = {owners => [
		{kind => 'vm', uuid => 'guest-id', name => 'guest'},
		{kind => 'snapshot', uuid => 'guest-id', name => 'guest'},
		{kind => 'backing', name => 'child.qcow2'},
	]};
	is(scalar(() = show_storage_volume_usage($usage) =~ /machine.cgi/g), 1, 'multiple references show each VM once');
	is(show_storage_volume_usage({owners => [{kind => 'image', name => 'Rocky Linux'}]}), '&mdash;', 'imported image without VM use has no Used by value');
}
# Directory links reuse Image Manager's ACL-aware path handling.
{
	no warnings qw(redefine once);
	my $root = tempdir('/tmp/cloudmin-filemin.XXXXXX', CLEANUP => 1);
	my $dir = "$root/disks & <images>";
	make_path($dir);
	my $volume = $pool->{'volumes'}->[0];
	local $volume->{'path'} = "$dir/disk.qcow2";
	my @allowed = ($root);
	local *foreign_require = sub { };
	local *filemin::get_allowed_paths = sub { @allowed };
	$html = show_storage_volumes([$pool], 'token', 1);
	like($html, qr/<b>Directory<\/b>/, 'directory has its own column');
	my $escaped = html_escape($dir);
	like($html, qr{\Q$escaped\E</tt>}, 'directory is escaped and excludes the filename');
	like($html, qr/<details\b[^>]*><summary>Storage location<\/summary>.*?disk\.qcow2.*?<\/details>/s,
		'full filename is kept in collapsed storage details');
	unlike($html, qr/filemin\//, 'unavailable File Manager leaves directory plain');
	local *foreign_available = sub { 1 };
	$html = show_storage_page($data, 'token', 'volumes');
	my $relative = urlize('/disks & <images>');
	like($html, qr{filemin/index\.cgi\?path=\Q$relative\E}, 'single File Manager root uses a relative directory URL');
	my $image = show_image_path($volume->{'path'});
	like($image, qr{filemin/index\.cgi\?path=\Q$relative\E}, 'Image Manager retains the same destination');
	like($image, qr{disk\.qcow2</tt>}, 'Image Manager still displays the full path');
	{
		local $data->{'local'} = 0;
		unlike(show_storage_page($data, 'token', 'volumes'), qr/filemin\//, 'remote storage never links to local File Manager');
	}
	@allowed = ($root, '/var/tmp');
	my $absolute = urlize($dir);
	like(show_storage_volumes([$pool], 'token', 1), qr{filemin/index\.cgi\?path=\Q$absolute\E}, 'multiple roots keep the absolute directory');
	@allowed = ("$root/elsewhere");
	unlike(show_storage_volumes([$pool], 'token', 1), qr/filemin\//, 'directory outside allowed roots has no link');
	@allowed = ('/');
	$volume->{'path'} = '/disk.qcow2';
	like(show_storage_volumes([$pool], 'token', 1), qr{filemin/index\.cgi\?path=%2[fF]}, 'file at filesystem root links to root');
	$volume->{'path'} = 'rbd:pool/disk';
	unlike(show_storage_volumes([$pool], 'token', 1), qr/filemin\//, 'non-filesystem volume has no directory link');
}
# Generated filenames are display details, while form values retain exact IDs.
{
my $name = 'cloudmin-alma10-system-'.('a'x32).'.qcow2';
my $volume = {name => $name, path => '/pool/'.$name, capacity => 1024**3, allocation => 0};
my $html = show_storage_volumes([{%$pool, volumes => [$volume]}], 'token', 0);
like($html, qr{cloudmin-storage-volume-name[^>]*>alma10 - System disk \([a-f0-9]{8}\)</span>},
    'storage table replaces a generated filename with its role and short reference');
like($html, qr{<details\b[^>]*><summary>Storage location</summary>.*?\Q$name\E.*?</details>}s,
    'storage details preserve the complete filename');
like($html, qr{name="volume"[^>]*value="[^" ]+/\Q$name\E"}, 'storage submission still uses the real volume name');
is(storage_volume_label({name => 'my-database.qcow2'}), 'my-database.qcow2', 'administrator names are preserved');
# Generated legacy, snapshot and import names still identify distinct volumes.
like(storage_volume_label({name => 'cloudmin-snapshot-'.('b'x32).'-vda.qcow2'}),
    qr/^Snapshot disk \(vda\) \([a-f0-9]{8}\)$/, 'snapshot volumes have readable labels');
like(storage_volume_label({name => 'cloudmin-seed-'.('c'x32).'.iso'}),
    qr/^Cloud-init configuration \([a-f0-9]{8}\)$/, 'legacy setup volume names are recognized');
isnt(storage_volume_label({name => 'cloudmin-snapshot-'.('b'x32).'-vda.1791549256'}),
    storage_volume_label({name => 'cloudmin-snapshot-'.('b'x32).'-vda.1791549257'}),
    'separate restores of one snapshot have distinct labels');
# Prefer the image's saved display name over its generated filename slug.
like(storage_volume_label({name => 'cloudmin-ubuntu-24-'.('d'x32).'.qcow2',
    usage => {owners => [{kind => 'image', name => 'Ubuntu 24.04'}]}}),
    qr/^Ubuntu 24\.04 - Disk image \(/, 'imported volumes use their saved image name');
}

# Group selection uses discovered names and never substitutes another group.
{
	my $form = show_storage_create('token', {}, ['guests', 'other']);
	like($form, qr/<select\b[^>]*name="group"/, 'LVM groups use a select field');
	like($form, qr/<option\b[^>]*value="guests"[^>]*>guests<\/option>/,
		'discovered group is available');
	like($form, qr{</select>\s*<a\b(?=[^>]*\bui_action\b)[^>]*href="../lvm/"[^>]*>.*?Manage.*?</a>}s,
		'Manage uses a standard action button beside the group selector');
	like($form, qr/\bui_toggle\b/, 'start at boot uses the shared toggle');
	like(storage_input($form, 'autostart'), qr/\bchecked\b/, 'start at boot defaults to enabled');
	$form = show_storage_create('token', {action => 'create', type => 'logical', group => 'other'},
		['guests', 'other']);
	like($form, qr/<option\b[^>]*value="other"[^>]*selected/, 'failed creation retains its group');
	unlike(storage_input($form, 'autostart'), qr/\bchecked\b/, 'failed creation retains disabled startup');
	$form = show_storage_create('token', {group => 'removed'}, ['guests']);
	like($form, qr/<option\b[^>]*value=""[^>]*selected/, 'removed group returns to the selection prompt');
	unlike($form, qr/<option\b[^>]*value="guests"[^>]*selected/, 'another group is never selected implicitly');
	$form = show_storage_create('token', {}, []);
	like($form, qr/No volume groups available/, 'empty inventory explains why there are no choices');
	$form = show_storage_page({%$data, lvm_group_error => 'read <failed>'}, 'token', 'pools');
	like($form, qr/Cannot list LVM volume groups: read &lt;failed&gt;/, 'discovery errors are escaped and shown');
	like($form, qr/name="path"/, 'directory creation survives an LVM discovery error');
}

# Pool removal uses a separate review; its submit button is the confirmation.
{
    local $pool->{unregisterable} = 1;
    like(show_storage_pool($pool, 'token'), qr/value="review_pool"/, 'pool card offers a review');
    unlike(show_storage_pool($pool, ''), qr/value="review_pool"/, 'read-only card has no unregister control');
    my $review = {id => $pool->{uuid}, name => '<pool>', path => '/storage/<path>',
        revision => 'revision', usage => {owners => [], reason => ''}};
    my $form = show_storage_unregister($review, 'token');
    like($form, qr/&lt;pool&gt;/, 'review escapes pool name');
    like($form, qr{<tt>/storage/&lt;path&gt;</tt>}, 'review formats only the escaped path as code');
    like(storage_input($form, 'action'), qr/value="unregister"/, 'review posts removal separately');
    like(storage_input($form, 'confirm'), qr/type=['"]hidden['"].*value="1"/,
        'submitting the review confirms removal without a toggle');
    # Active LVM reviews explain that stopping affects the entire group.
    {
        local $review->{stop_required} = 1;
        local $review->{type} = 'logical';
        my $active = show_storage_unregister($review, 'token');
        like($active, qr/Stop and Unregister/, 'active pool offers a combined action');
        like($active, qr/deactivates every logical volume/, 'whole-group effect is explained');
        like(storage_input($active, 'stop'), qr/value="1"/, 'confirmed UI action passes stop permission');
        like(storage_input($active, 'confirm'), qr/type=['"]hidden['"].*value="1"/,
            'submitting the combined action confirms removal without a toggle');
    }
    # A blocked review escapes the reason and offers no removal submission.
    local $review->{usage}->{reason} = 'Stop <pool> first';
    $form = show_storage_unregister($review, 'token');
    like($form, qr/Stop &lt;pool&gt; first/, 'blocked review explains refusal');
    unlike($form, qr/name="confirm"|value="unregister"/, 'blocked review cannot submit removal');
}

# NFS fields retain user input and use Webmin's existing backend selector.
{
    my $form = show_storage_create('token', {action => 'create', type => 'netfs',
        server => 'nas.example.test', export => '/guests', mount => '/var/lib/libvirt/shared'});
    like(storage_input($form, 'server'), qr/value="nas.example.test"/, 'NFS server is retained');
    like(storage_input($form, 'export'), qr/value="\/guests"/, 'NFS export is retained');
    like(storage_input($form, 'mount'), qr/value="\/var\/lib\/libvirt\/shared"/, 'NFS mount is retained');
    like($form, qr/name="type"[^>]*value="netfs"[^>]*checked/, 'NFS backend remains selected');
}

done_testing();
