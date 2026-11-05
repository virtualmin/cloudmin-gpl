use strict;
use warnings;

use FindBin qw($Bin);

use lib "$Bin/lib";
use CloudminTest;

use Test::More;
use WebminCore;

# Supply the translations and asset root normally loaded by init_config.
our (%text, %config, $root_directory);
our $module_root_directory = "$Bin/..";
$root_directory = $CloudminTest::webmin_root;
%WebminCore::text = (%WebminCore::text, nice_size_GiB => 'GiB');

open(my $lang, '<', "$Bin/../lang/en") || die "Cannot read lang/en: $!";
while (my $line = <$lang>) {
	$line =~ s/\r?\n$//;
	# Only key=value entries contribute text used by the page builders.
	if ($line =~ /^([^=]+)=(.*)$/) {
		$text{$1} = $2;
		}
	}
close($lang);

require "$Bin/../cloudmin-pages.pl";

# Model a ready host with one running guest to exercise the populated dashboard.
my $data = {
	'ready' => 1,
	'host' => {
		'hostname' => 'kvm1.example.test',
		'driver' => 'QEMU',
		'uri' => 'qemu:///system',
		'libvirt_version' => '11.10.0',
		'libvirt_layout' => 'modular',
		'hypervisor_version' => '10.2.0',
	},
	# One check is enough to exercise the requirement-list widgets.
	'readiness' => {
		'checks' => [
			{
				'label' => 'Libvirt connection',
				'detail' => 'Connected.',
				'ok' => 1,
			},
		],
	},
	# The guest name contains markup so the rendered page must escape it.
	'servers' => [
		{
			'name' => '<unsafe-vm>',
			'state' => 'running',
			'vcpus' => 2,
			'memory_kib' => 1024 * 1024,
			'macs' => [ '52:54:00:aa:bb:cc' ],
			'addresses' => [ { address => '192.0.2.10' },
			{ address => '2001:db8::10' } ],
			'persistent' => 1,
			'active' => 1,
			},
	],
	'counts' => {
		'hosts' => 1,
		'vms' => 1,
		'running' => 1,
		'jobs' => 0,
	},
};
my $html = show_dashboard_page($data);
# Compact host information must still expose failures and avoid dangling links.
{
	local $config{'host_details'} = 'problems';
	my $compact = show_dashboard_page($data);
	unlike($compact, qr/id="cloudmin-host"|href="#cloudmin-host"/,
		'healthy compact overview omits the host card and its anchor link');
	my $failed = show_dashboard_page({%$data, ready => 0});
	like($failed, qr/id="cloudmin-host"/,
		'failed host requirements remain visible in compact mode');
}


# Exercise real widget markup and host details without depending on a theme.
like($html, qr/class=['"][^'"]*\bui_page\b/, 'dashboard uses the widget page');
like($html, qr/class=['"][^'"]*\bui_stats\b/,
	'dashboard renders statistic widgets');
like($html, qr/class=['"][^'"]*\bui_card\b/, 'dashboard renders cards');
like($html, qr/QEMU/, 'dashboard renders host details');
like($html, qr/11\.10\.0/, 'dashboard renders the libvirt version');
like($html, qr/Libvirt services.*Modular/s,
	'host card identifies the modular layout');
my $monolithic = show_dashboard_page({ %$data,
	host => { %{$data->{'host'}}, libvirt_layout => 'monolithic' } });
like($monolithic, qr/Libvirt services.*Monolithic/s,
	'host card identifies the monolithic layout');
like($html, qr/10\.2\.0/, 'dashboard renders the QEMU version');
# Guest-controlled text must be escaped.
like($html, qr/&lt;unsafe-vm&gt;/, 'virtual machine names are escaped');
unlike($html, qr/<unsafe-vm>/, 'raw virtual machine names are not emitted');
like($html, qr/Operating system/, 'overview includes an operating system column');
like($html, qr/data-vm-guest="os"/, 'overview uses the existing live guest OS field');
like($html, qr/IP addresses/, 'overview includes an IP address column');
like($html,
	qr/<tt\b[^>]*>192\.0\.2\.10<\/tt>\s*<br><tt\b[^>]*>2001:db8::10<\/tt>/,
	'overview shows every reported address as plain monospace text');
is(get_vm_row({ %{$data->{'servers'}->[0]}, addresses => [] })->[3],
	'Not reported', 'missing addresses have a clear fallback');

# Live configuration stays on the page root and preserves nested HTML entities.
my $live_html = show_dashboard_page({ %$data, live => 1,
	status_config =>
		'{"rows":["<span>&quot;quoted&quot; &amp; text</span>"]}' });
my ($live_root) = $live_html =~ /(<div\b[^>]*\bclass="[^"]*\bui_page\b[^>]*>)/;
like($live_root, qr/\bid="cloudmin-vm-status"/,
	'live status uses the existing page root');
like($live_root,
	qr/data-config="\{&quot;rows&quot;:\[&quot;&lt;span&gt;&amp;quot;quoted&amp;quot; &amp;amp; text&lt;\/span&gt;&quot;\]\}"/,
	'row template entities survive attribute decoding without changing JSON');
is(scalar(() = $live_html =~ /\bid="cloudmin-vm-status"/g), 1,
	'only one live status container is emitted');
my ($status_warning) =
	$live_html =~ /(<div\b[^>]*data-vm-status-warning="1"[^>]*>)/;
like($status_warning, qr/\bhidden(?:\s|>)/, 'connection warning starts hidden');
like($live_html, qr/Virtual machine controls are unavailable until live status connects/,
	'overview explains blocked controls');
unlike($html, qr/data-vm-status-warning|data-config=/,
	'static dashboard has no live status configuration or warning');

# Controls use fresh guest state and disappear without a write token.
my $guest = { %{$data->{'servers'}->[0]},
	uuid => '11111111-2222-3333-4444-555555555555', autostart => 0 };
my $running_row = get_vm_row($guest, 'signed-token');
like($running_row->[10], qr/value="shutdown".*value="reboot"/s,
	'running guests offer clean shutdown and reboot');
# Standard buttons bypass link conversion and its extra wrapper.
like($running_row->[10], qr/\A<div\b[^>]*\bui_cluster\b/,
	'power controls share one layout wrapper');
is(scalar(() = $running_row->[10] =~ /<button\b[^>]*\bui_action_small\b/g), 3,
	'all running actions are small buttons');
like($running_row->[10], qr/value="suspend".*ui_svg_icon_pause.*Pause/s,
	'Pause includes its icon and label');
unlike($running_row->[10], qr/<a\b|data-btns| \| /,
	'controls contain no legacy links, wrappers or separators');
unlike($running_row->[10], qr/value="start"/,
	'active guest has no start button');
unlike($running_row->[9], qr/\schecked(?:\s|>)/,
	'disabled boot policy renders an unchecked toggle');
my $stopped_row = get_vm_row({ %$guest, state => 'shutoff', active => 0,
	autostart => 1 }, 'signed-token');
like($stopped_row->[9], qr/\schecked(?:\s|>)/,
	'enabled boot policy renders a checked toggle');
like($stopped_row->[10], qr/value="start"/, 'stopped guest has a start button');
unlike($stopped_row->[10], qr/value="(?:shutdown|reboot)"/,
	'stopped guest has no shutdown or reboot button');
like(get_vm_row({ %$guest, state => 'paused' }, 'signed-token')->[10], qr/value="resume"/,
	'paused guest offers Resume');
unlike(join('', @{get_vm_row($guest)}), qr/<form|<button/,
	'read-only inventory has no mutation controls');
unlike(get_vm_row({ %$guest, persistent => 0 }, 'signed-token')->[9], qr/<form/,
	'transient guests cannot enable autostart');

# Settings belong in Webmin's page header, not in a second dashboard button.
unlike($html, qr{config\.cgi|Configure Cloudmin},
	'dashboard does not duplicate the header configuration control');

# Keep the overview tiles concise, with icons and labels.
my ($overview) =
	$html =~ /(<section\b[^>]*\bid="cloudmin-overview".*?<\/section>)/s;
ok($overview, 'statistics have a dedicated overview card');
like($overview, qr/\bui_stats\b/, 'overview card contains statistic tiles');
is(scalar(() = $overview =~ /<svg\b/g), 4, 'each statistic has a leading icon');
unlike($overview, qr/\bui_stat_desc\b/, 'statistics omit redundant captions');
unlike($html, qr/\bui_card_desc\b/, 'dashboard cards omit redundant descriptions');

# The linked tiles must point to sections that exist on this page.
like($overview, qr/href="#cloudmin-host"/, 'host tile links to host details');
like($html, qr/\bid="cloudmin-host"/, 'host link target exists');
like($overview, qr/href="#cloudmin-machines"/, 'VM tile links to the VM list');
like($html, qr/\bid="cloudmin-machines"/, 'VM link target exists');
like($overview, qr/href="jobs\.cgi"/,
	'active jobs has a stable destination even at zero');
unlike($overview, qr/href="(?:images|machine_jobs)\.cgi"/,
	'job tile does not switch between unrelated inventories');

# The status-only destination shows both job types without leaving the page.
my $jobs_html = show_jobs_page({ jobs => [
	{ type => 'image', id => 'a'x32, name => '<image>',
	  state => 'downloading', bytes => 256, total => 1024, created => 1 },
	{ type => 'vm', id => 'b'x32, name => '<guest>', state => 'running',
	  phase => 'disk', created => 2 },
] });
unlike($jobs_html, qr/<(?:button|input|form)\b/,
	'jobs overview does not perform mutations');
like($jobs_html, qr/progress\.cgi\?job=b{32}/,
	'jobs overview links to operation details and recovery');
like($jobs_html, qr/aria-valuenow="25"/,
	'image transfer displays measured progress');
like($jobs_html, qr/\bui_progress_indeterminate\b/,
	'VM step shows activity without an invented percentage');
like($jobs_html, qr/&lt;image&gt;.*&lt;guest&gt;/s,
	'mixed job names are escaped');
like($jobs_html, qr/Downloading image.*Preparing virtual machine disk/s,
	'both job types show their current phase');
my $empty_jobs = show_jobs_page({ jobs => [] });
like($empty_jobs, qr/\bui_empty\b.*\bui_empty_icon\b.*No active jobs/s,
	'no jobs has a centered empty state with an icon');
unlike(show_jobs_status({ jobs => [] }), qr/<(?:table|a|button|input|form)\b/,
	'empty status has no table headers or buttons');
my $failed_jobs = show_jobs_page({ jobs => [], errors => ['<unavailable>'] });
like($failed_jobs, qr/&lt;unavailable&gt;/,
	'job-store failures are escaped and shown');
unlike($failed_jobs, qr/No active jobs/,
	'a failed lookup is not reported as an empty queue');
# Recovery remains actionable without full-size controls in the jobs table.
my $recovery_jobs = show_jobs_status({ jobs => [{ type => 'vm', id => 'd'x32,
	name => 'Recovery guest', state => 'failed', created => 1,
	cleanup_pending => 1, error => '<failed>' }] });
like($recovery_jobs, qr/class="[^"]*\bui_badge_small\b/,
	'recovery status uses a small badge');
unlike($recovery_jobs, qr/machine_jobs\.cgi/,
	'recovery does not send users to a duplicate job list');
like($recovery_jobs, qr/Recovery required.*&lt;failed&gt;/s,
	'recovery status includes the escaped error');
my $saving_job = { type => 'image', id => 'c'x32, name => 'Import',
	state => 'importing', bytes => 1024, total => 4096, transferred => 512,
	created => 1 };
like(show_jobs_status({ jobs => [$saving_job] }), qr/aria-valuenow="50"/,
	'storage transfer uses bytes saved, not the earlier download size');
unlike(show_jobs_status({ jobs => [{ %$saving_job, cancel => 1 }] }),
	qr/aria-valuenow/,
	'cancellation does not retain a stale percentage');
like(show_jobs_status({ jobs => [{ %$saving_job, transferred => 2048 }] }),
	qr/aria-valuenow="100"/,
	'transfer progress is capped at the reported total');
unlike(show_jobs_status({ jobs => [{ %$saving_job, bytes => 0 }] }),
	qr/aria-valuenow/,
	'an unknown size shows activity without dividing by zero');

# Keep useful next steps when the inventory is empty.
my $empty_html = show_dashboard_page({ %$data, 'servers' => [] });
like($empty_html,
	qr/No virtual machines yet.*Create your first virtual machine on kvm1\.example\.test\./s,
	'empty inventory explains the next step and identifies the host');

# Render the image and storage selection form with one full image fixture.
my $image = {
	'id' => 'rocky-linux-10',
	'name' => 'Rocky Linux 10',
	'vendor' => 'Rocky Enterprise Software Foundation',
	'os' => 'Rocky Linux',
	'release' => '10',
	'release_date' => '2025-06-11',
	'end_of_life' => '2035-05-31',
	'status' => 'recommended',
	'architecture' => 'aarch64',
	'format' => 'qcow2',
	'firmware' => 'uefi',
	'min_disk_bytes' => 10 * 1024 * 1024 * 1024,
	'cloud_init' => 1,
	'guest_agent' => 1,
	'source_url' => 'https://download.example.test/rocky/',
	'url' => 'https://download.example.test/rocky-10.qcow2',
	'checksum_url' => 'https://download.example.test/CHECKSUM',
	'signature_url' => 'https://download.example.test/CHECKSUM.asc',
};
my @form_images = (
	{ %$image, 'id' => 'almalinux-10', 'name' => 'AlmaLinux 10', os => 'AlmaLinux' },
	{ %$image, 'id' => 'debian-13', 'name' => 'Debian 13', os => 'Debian', release => '13' },
	$image,
	{ %$image, 'id' => 'ubuntu-24.04', 'name' => 'Ubuntu 24.04 LTS', os => 'Ubuntu', release => '24.04' },
);
my $pool = {
	'id' => 'pool-default',
	'name' => 'default',
	'available' => 40 * 1024 * 1024 * 1024,
};
my $images_html;
{
	no warnings qw(once redefine);
	# theme_nice_size(bytes) simulates a theme returning markup around a size.
	local *WebminCore::theme_nice_size = sub {
		my ($bytes) = @_;
		return '<span data-filesize-bytes="'.$bytes.'">'.
			($bytes / 1024**3).' GiB</span>';
		};
	local $main::header_content_type = 'text/html';
	local $main::webmin_script_type = 'web';
	$images_html = show_images_page({
		'images' => \@form_images, 'pools' => [ $pool ],
		'architecture' => 'aarch64', 'token' => 'test-form-token',
	});
	}
like($images_html, qr/Add Images/, 'image import form is rendered');
like($images_html, qr/method=['"]post['"]/, 'imports use POST');
like($images_html, qr/name=['"]token['"]/, 'form contains CSRF token');
like($images_html, qr/name=['"]install_type['"]/, 'source is a dropdown');
like($images_html,
	qr/name=['"]pool['"].*<hr\b.*name=['"]install_type['"].*id=['"]cloudmin-image-download['"]/s,
	'pool precedes the separator, image source and image selection');
for my $name ('AlmaLinux 10', 'Debian 13', 'Rocky Linux 10',
	'Ubuntu 24.04 LTS') {
	like($images_html, qr/\Q$name\E/, "$name is available");
	}
for my $source ('Download an OS', 'Download from a URL', 'Upload an image',
		'Use an image on this host') {
	like($images_html, qr/\Q$source\E/, "$source has an actionable option");
	}
like($images_html, qr/default.*40 GiB available/s, 'pool shows readable space');
like($images_html, qr/Download Selected Images/,
	'button states the batch action');
like($images_html, qr/hiddendiv_image_advanced/,
	'advanced options are collapsed');
like($images_html, qr/id=['"]div_images['"]/,
	'images inventory has its own tab');
like($images_html, qr/id=['"]div_add['"]/, 'add images has its own tab');
for my $key (qw(images_manage_desc images_add_desc)) {
	my $description = quotemeta(html_escape($text{$key}));
	like($images_html,
		qr/<div\b[^>]*class=['"][^'"]*\bvui_ui_block\b[^'"]*['"][^>]*>\s*<p\b[^>]*>$description<\/p>\s*<\/div>/,
		"$key uses the Podman tab-description wrapper");
	}
like($images_html, qr/data-ui-multi=['"]id['"]/,
	'catalogue uses the multi-select list');
like($images_html, qr/action=['"]setup_image.cgi['"]/,
	'form submits to a native progress page');
unlike($images_html, qr/class=['"][^'"]*\bui_card\b/,
	'image manager does not wrap forms in cards');
my $checked = show_images_page({ images => \@form_images, pools => [ $pool ],
	jobs => [ { id => 'a'x32, state => 'downloading', updated => time(),
	created => time(),
		name => '<test>', pool => $pool->{'id'}, pool_name => 'default',
		format => 'qcow2',
		bytes => 1000, total => 2000, volume => 'fixture.qcow2' } ] });
like($checked, qr/data-sortable=['"]1['"]/,
	'checked image table is a DataTable');
like($checked, qr/type=['"]checkbox['"][^>]*name=['"]job['"]/,
	'active downloads can be selected');
like($checked, qr/Delete Selected Images/, 'bulk deletion is available');
like($checked, qr/&lt;test&gt;/, 'image names remain escaped');
unlike($checked, qr{href=['"]setup_image\.cgi\?job=},
	'active transfer has no progress link');
is(scalar(() = $checked =~ /href=['"]image_form\.cgi/g), 1,
	'Add images tab has no duplicate table shortcuts');
is(scalar(() = $images_html =~ /href=['"]image_form\.cgi/g), 1,
	'empty inventory has no duplicate Add images shortcuts');
for my $state (qw(queued waiting downloading uploading copying verifying
		  importing ready failed interrupted)) {
	my $finished = show_images_page({ images => \@form_images,
		pools => [ $pool ],
		jobs => [ { id => 'b'x32, state => $state, updated => time(),
		created => time(),
			name => 'Finished image', pool => $pool->{'id'},
			pool_name => 'default',
			format => 'qcow2', bytes => 1000,
			volume => 'fixture.qcow2',
			error => $state eq 'failed' ? 'Checksum <mismatch>'
			: '' } ] });
	unlike($finished,
		qr{View progress|data-image-progress|href=['"]setup_image\.cgi\?job=},
		"$state image has no progress link");
	like($finished, qr/<span\b[^>]*data-image-error=[^>]*>Checksum &lt;mismatch&gt;<\/span>/,
		'failed image retains escaped error details')
			if ($state eq 'failed');
	}
like($images_html, qr/images\.js/, 'page loads progress and upload behavior');
unlike($images_html,
	qr/Continue|Image details|Create new virtual machine|disk_size/,
	'no review dead end or unimplemented VM controls');
my $status = get_image_job_status({
	id => 'a'x32, state => 'importing', updated => time(), name => 'Debian',
	pool_name => 'default', bytes => 1000, transferred => 500,
});
is($status->{'percent'}, 50, 'import progress uses transferred bytes');
ok(!$status->{'terminal'}, 'importing is not complete');
$status = get_image_job_status({
	id => 'b'x32, state => 'failed', error => 'Checksum mismatch',
});
is($status->{'detail'}, 'Checksum mismatch', 'failure explains what happened');
ok($status->{'terminal'}, 'failure stops polling');

# Catalogue controls show all architectures and keep untrusted metadata escaped.
my $catalogue_html = show_catalogue_page({ token => 'fixture-token',
	catalogue_entries => [
	{ %$image, name => '<Custom image>',
	catalogue_key => 'custom-fixture:aarch64',
	  catalogue_origin => 'custom', enabled => 1 },
] });
like($catalogue_html, qr/&lt;Custom image&gt;/, 'catalogue names are escaped');
like($catalogue_html, qr/edit_catalog_image\.cgi\?key=/,
	'each catalogue entry can be opened');
like($catalogue_html, qr/Add custom image/,
	'catalogue has a custom-entry action');
like($catalogue_html, qr/name=['"]token['"]/,
	'catalogue controls include a signed token');
my $readonly_catalogue = show_catalogue_page({ readonly => 1,
	catalogue_entries => [] });
unlike($readonly_catalogue,
	qr/Add custom image|Enable Selected|Delete Custom Entries/,
	'read-only catalogue hides write controls');
my $editor = show_catalogue_form({ %$image, architecture => 'aarch64' }, 1,
	'fixture-token');
like($editor, qr/name=['"]checksum_url['"]/,
	'editor exposes the checksum file URL');
like($editor, qr/name=['"]checksum_algorithm['"]/,
	'editor exposes the checksum algorithm');
# Both catalogue rows and download choices identify their source.
like($catalogue_html, qr/>Custom</,
	'custom catalogue row has an explicit source');
like($images_html, qr/id=['"]div_catalogue['"]/, 'catalogue has the third tab');
my $custom_choice = show_images_page({ pools => [ $pool ], images => [
	{ %$image, catalogue_origin => 'custom' },
	{ %$image, id => 'bundled-fixture', catalogue_origin => 'bundled' },
] });
unlike($custom_choice, qr/>ARM64</,
	'host-filtered choices omit repeated architecture');
like($custom_choice, qr/>Custom</, 'custom downloads remain identifiable');
like($images_html, qr/Official cloud images<\//,
	'official origin is shared in the toolbar');
like($images_html,
	qr/listed in <a [^>]*href="images\.cgi\?mode=catalogue"[^>]*>Image Catalogue<\/a>\s+and checks each file/,
	'download explanation links to source URLs within the sentence');
like($custom_choice, qr/Custom images use URLs supplied by an administrator/,
	'mixed lists distinguish custom sources from official images');
like($custom_choice, qr/ui_multi_group_neutral[^>]*>.*?<span[^>]*>Rocky Linux<\/span>/s,
	'downloads use distribution headings');
# Mixed support levels must not separate releases of the same distribution.
my $grouped_downloads = show_images_page({ pools => [$pool], images => [
	{%$image, id => 'rocky10'},
	{%$image, id => 'debian9', name => 'Debian 9', os => 'Debian', release => '9', status => 'older'},
	{%$image, id => 'rocky9', name => 'Rocky Linux 9', release => '9', status => 'supported'},
	{%$image, id => 'debian13', name => 'Debian 13', os => 'Debian', release => '13'},
] });
is_deeply([$grouped_downloads =~ /data-download-id="([^"]+)"/g],
	[qw(debian13 debian9 rocky10 rocky9)],
	'Add Images follows the shared distribution and version order');
is_deeply([$grouped_downloads =~ /<div\b(?=[^>]*data-ui-multi-heading)[^>]*>.*?<span[^>]*>(.*?)<\/span>/sg],
	['Debian', 'Rocky Linux'], 'each distribution gets one download heading');
is(get_image_option({name => 'Unclassified image'})->{'group'}->{'label'},
	$text{'vm_image_other'}, 'images without distribution metadata have a fallback heading');
is(scalar(() = $custom_choice =~ /\bui_multi_metadata\b/g), 2,
	'each image has one combined metadata badge');
unlike($images_html, qr/ui_multi_count/,
	'download choices omit the selection count');
my $unknown = get_image_option({ %$image, status => 'older',
	end_of_life => undef }, '2026-09-23');
is($unknown->{'group'}->{'label'}, 'Rocky Linux',
	'older releases stay in their distribution group');
is($unknown->{'metadata'}->[-1]->{'state'}, 'danger',
	'older releases retain their support badge color');
is($unknown->{'metadata'}->[0]->{'label'}, 'Size unknown',
	'missing download size is explicit');
is($unknown->{'metadata'}->[-1]->{'label'}, 'Support date unknown',
	'missing custom support dates are explicit');
my $rolling = get_image_option({ %$image, release => 'rolling',
	end_of_life => undef });
is($rolling->{'metadata'}->[-1]->{'label'}, 'Rolling updates',
	'rolling releases do not invent a support deadline');
my $planned = get_image_option({ %$image, end_of_life_planned => 1 });
like($planned->{'metadata'}->[-1]->{'title'}, qr/Planned support end date/,
	'tentative dates are identified in the tooltip');
for my $status (qw(recommended supported older)) {
	my $option = get_image_option({ %$image, status => $status,
		download_size_bytes => 1024**3 });
	is($option->{'metadata'}->[0]->{'state'},
		$option->{'metadata'}->[-1]->{'state'},
		"$status download size uses the support text and icon color");
	unlike($option->{'metadata'}->[0]->{'label'}, qr/~/,
		'download size has no approximation marker');
	}
my $expired = get_image_option({ %$image, status => 'recommended',
	end_of_life => '2026-08-31' }, '2026-09-23');
is($expired->{'status'}, 'older',
	'expired support overrides a stale recommendation');
is($expired->{'metadata'}->[-1]->{'label'}, 'Support ended 2026',
	'expired support has clear wording');
is($expired->{'metadata'}->[-1]->{'title'}, 'Support ended 2026-08-31',
	'tooltip retains the full support date');
is($expired->{'metadata'}->[-1]->{'state'}, 'danger',
	'expired support uses red text and icon');
my $last_day = get_image_option({ %$image, end_of_life => '2026-09-23' },
	'2026-09-23');
is($last_day->{'metadata'}->[-1]->{'label'}, 'Support until 2026',
	'support includes its last calendar day');
my $unknown_older = get_image_option({ %$image, status => 'older',
	end_of_life => undef });
ok(!grep(($_->{'label'} || '') =~ /Support ended/,
	@{$unknown_older->{'metadata'}}),
	'older alone does not claim the vendor has ended support');
my $details = show_catalogue_form({ %$image, catalogue_origin => 'bundled' }, 0, '',
	undef, 1);
unlike($details, qr/<form|<input|<select/,
	'Cloudmin details contain no editable controls');
like($details, qr/CHECKSUM/, 'read-only details include the checksum location');
unlike($catalogue_html, qr/<details\b|SHA256|SHA512/,
	'catalogue has no URL disclosures or checksum algorithms');
like($catalogue_html, qr/>Available</,
	'catalogue reports checksum availability without claiming verification');
like($catalogue_html,
	qr/<a\b(?=[^>]*class="[^"]*\bui_link\b)(?=[^>]*href="https:\/\/download\.example\.test\/CHECKSUM")[^>]*>.*?Checksum<\/a>/s,
	'checksum file has a separate download button');
like($catalogue_html, qr/Release date.*?End of life.*?2025-06-11.*?2035-05-31/s,
	'catalogue includes sortable lifecycle dates');
unlike($catalogue_html,
	qr/Operating system \/ release|<summary>URLs<\/summary>/i,
	'catalogue headings have no redundant words');
like($details, qr/10 GiB/, 'read-only disk size includes its unit');
unlike($details, qr/Checksum algorithm/,
	'an absent checksum algorithm has no empty detail row');
unlike($details, qr/\(HTTPS\)|\(optional\)|0 for unspecified|Image Details/,
	'details omit editor instructions and the repeated title');
for my $url ($image->{'url'}, $image->{'checksum_url'},
	$image->{'source_url'}) {
	like($details, qr/<a\b[^>]*href="\Q$url\E"/,
		'catalogue URL is clickable');
	}
my $unknown_details = show_catalogue_form({ %$image, min_disk_bytes => 0,
	cloud_init => undef, guest_agent => undef,
	catalogue_origin => 'bundled' }, 0, '', undef, 1);
like($unknown_details, qr/Unknown/, 'unspecified disk size is unknown');
unlike($unknown_details, qr/Supports cloud-init|Includes QEMU guest agent/,
	'unknown compatibility flags are omitted instead of reported as No');
like($editor, qr/name=['"]min_disk_gib_def['"]/,
	'disk size uses Webmin unknown-or-value control');
like($editor, qr/name=['"]release_date['"]/,
	'custom editor exposes release date');
like($editor, qr/name=['"]end_of_life['"]/,
	'custom editor exposes end-of-life date');
my $checksum = get_image_job_status({ state => 'ready', verified => 'sha256',
	checksum_digest => 'a'x64 });
is($checksum->{'checksum'}, 'Passed', 'verified checksum has a plain result');
is($checksum->{'checksum_html'}, 'Passed',
	'checksum cell has no disclosure, algorithm or digest');
my $old_checksum = get_image_job_status({ state => 'ready', verified => 'sha256' });
is($old_checksum->{'checksum'}, 'Passed',
	'legacy verification keeps its recorded result');
my $unverified = get_image_job_status({ state => 'ready', sha256 => 'a'x64 });
is($unverified->{'checksum'}, 'Not verified',
	'a supplied but unchecked digest is not marked as passed');

# Creation pages separate network, access and boot settings and preserve values.
# Details use the existing signed POST action, never a state-changing URL.
{
no warnings 'once';
# get_status_config(vm, [reopen]) supplies minimal JSON for page rendering tests.
local *main::get_status_config = sub { return '{}'; };
my $vm = { %$guest, state => 'shutoff', active => 0, addresses => [] };
my $details = show_vm_details($vm, 'fixture-token');
# Empty device sections explain what is missing without displaying column headings.
like($details, qr/No network interfaces are configured for this virtual machine\./,
	'empty network configuration has an explanation');
unlike($details, qr/>Host device</, 'empty network section omits its table headings');
like($details, qr/Start this virtual machine to view its mounted filesystems\./,
	'stopped guest explains how to get filesystem information');
my ($filesystems) = $details =~ /(<div\b[^>]*data-vm-filesystems="1"[^>]*>)/;
like($filesystems, qr/\bhidden(?:\s|>)/, 'filesystem table starts hidden');
my $with_nic = show_vm_details({ %$vm, interfaces => [{
	mac => '52:54:00:00:00:01', type => 'network', source => 'default', model => 'virtio',
}] });
like($with_nic, qr/52:54:00:00:00:01/, 'configured NICs remain visible when stopped');
unlike($with_nic, qr/No network interfaces are configured/, 'configured NICs omit the empty message');
my ($control) = $details =~ /(<div\b[^>]*data-vm-start="1".*?<\/form>\s*<\/div>)/s;
ok($control, 'stopped details offer Start beside the power state');
unlike($control, qr/\bhidden(?:\s|>)/, 'Start is initially visible for a stopped VM');
like($control, qr/<form\b[^>]*action=['"]machine\.cgi['"][^>]*method=['"]post['"]/,
	'details submit Start to the details page');
like($control, qr/name="token"[^>]*value="fixture-token"/,
	'Start carries the write token');
like($control, qr/name="id"[^>]*value="$guest->{'uuid'}"/,
	'Start targets the displayed guest');
like($control, qr/name="action"[^>]*value="start"/,
	'details submit only the start operation');
like($control, qr/<button\b(?=[^>]*\bui_action_small\b)(?=[^>]*\btype="submit")/,
	'details use small native submit buttons');
unlike(show_vm_details($vm), qr/data-vm-(?:start|running|active)|<form\b/,
	'details without a write token have no power controls');
my $running = { %$vm, state => 'running', active => 1 };
my $running_details = show_vm_details($running, 'fixture-token');
like($running_details, qr/Checking guest filesystems \.\./,
	'running guest waits for the first filesystem report');
my ($active_control) = $running_details =~
	/(<div\b[^>]*data-vm-start="1"[^>]*>)/;
like($active_control, qr/\bhidden(?:\s|>)/,
	'running details keep Start hidden until shutdown');
my ($running_controls) = $running_details =~ /(<div\b[^>]*data-vm-running="1".*?<\/form>\s*<\/div>)/s;
like($running_controls, qr/value="reboot".*value="shutdown"/s,
	'running details offer Reboot and Shut down');
unlike($running_controls, qr/^<div[^>]*\bhidden(?:\s|>)/,
	'running power buttons are visible');
is(scalar(() = $running_controls =~ /name="token"[^>]*value="fixture-token"/g), 2,
	'the two primary actions carry a write token');
my ($stopped_controls) = $details =~ /(<div\b[^>]*data-vm-running="1"[^>]*>)/;
like($stopped_controls, qr/\bhidden(?:\s|>)/,
	'stopped guests have no visible Reboot or Shut down buttons');
my $pending = show_vm_details($running, 'fixture-token', 1);
my ($pending_controls) = $pending =~ /(<div\b[^>]*data-vm-running="1"[^>]*>)/;
like($pending_controls, qr/\bhidden(?:\s|>)/,
	'a pending shutdown hides repeat power actions');
like($pending, qr/data-vm-shutdown-requested="1"/,
	'live status retains the pending shutdown until the guest stops');
my ($emergency) = $pending =~ /(<a\b[^>]*data-vm-active="1"[^>]*>)/;
# Emergency links open confirmation and remain available during shutdown.
unlike($emergency, qr/\bhidden(?:\s|>)/, 'pending shutdown keeps emergency power-off available');
like($emergency, qr/href="machine.cgi\?id=.*?&amp;force_off=1"/,
	'emergency menu entry opens the existing confirmation page');
like($emergency, qr/\bui_dropdown_item\b/, 'emergency action is a menu entry');
unlike($emergency, qr/(?:action|confirm)=/, 'emergency link cannot submit a mutation');
my ($stopped_emergency) = $details =~ /(<a\b[^>]*data-vm-active="1"[^>]*>)/;
like($stopped_emergency, qr/\bhidden(?:\s|>)/, 'stopped guests hide emergency power-off');
like($stopped_emergency, qr/aria-disabled="true"/, 'keyboard navigation skips hidden emergency links');
my ($menu) = $running_details =~ /(<form\b[^>]*id="vm-more-actions-form".*?<\/form>)/s;
# Secondary actions share a signed form but stay out of the primary row.
like($menu, qr/<details\b.*?More actions/s, 'secondary controls use the shared dropdown');
like($menu, qr/name="token"[^>]*value="fixture-token"/, 'menu submits with the signed token');
like($menu, qr/<button\b(?=[^>]*name="action")(?=[^>]*value="suspend")(?=[^>]*type="submit")/,
	'Pause submits its action through the menu form');
unlike($running_controls, qr/value="suspend"|value="power_cycle"|clone_machine_form/,
	'only Reboot and Shut down appear as primary running actions');
my ($stopped_pause) = $details =~ /(<button\b[^>]*value="suspend"[^>]*>)/;
like($stopped_pause, qr/\bhidden(?:\s|>)/, 'stopped guests hide Pause');
like($stopped_pause, qr/\bdisabled(?:\s|>)/, 'hidden Pause cannot submit or receive menu focus');
my ($cycle) = $running_details =~ /(<button\b[^>]*value="power_cycle"[^>]*>)/;
# Power cycling appears only when saved changes require a complete restart.
like($cycle, qr/\bhidden(?:\s|>)/, 'power cycle stays hidden without saved changes');
my $changed_details = show_vm_details({%$running, pending => {cpus => {running => 1, saved => 2}, bootmenu => {running => 0, saved => 1}}}, 'fixture-token');
($cycle) = $changed_details =~ /(<button\b[^>]*value="power_cycle"[^>]*>)/;
unlike($cycle, qr/\bhidden(?:\s|>)/, 'saved changes expose power cycle in the menu');
my $confirmation = show_vm_force_off_form({ %$running, name => 'guest<one>' }, 'fixture-token');
like($confirmation, qr/Force power off <tt>guest&lt;one&gt;<\/tt>\?/, 'confirmation names the guest safely');
like($confirmation, qr/Unsaved data will be lost and filesystems may be damaged/,
	'confirmation explains the consequence');
like($confirmation, qr/<form\b[^>]*action=['"]machine.cgi['"][^>]*method=['"]post['"]/,
	'confirmed power-off uses POST');
like($confirmation, qr/name="confirm"[^>]*value="1"/, 'confirmation carries explicit consent');
like($confirmation, qr/name="token"[^>]*value="fixture-token"/, 'confirmation carries the signed token');
like($confirmation, qr/name="action"[^>]*value="force_off"/, 'confirmation selects only emergency power-off');
like($confirmation, qr/class=['"]ui_submit['"][^>]*value=['"]Force Power Off['"]/,
	'confirmation uses the standard form submit button');
unlike($confirmation, qr/ui_action|>Cancel</, 'confirmation has no compact actions or Cancel button');
my $editor_confirmation = show_vm_force_off_form($running, 'fixture-token', 'edit_machine');
like($editor_confirmation, qr/name="return"[^>]*value="edit_machine"/, 'editor confirmation retains its return page');
}
# Hardware edits and power actions must submit different forms.
my $settings = { id => 'guest', revision => 'revision', active => 0, max_cpus => 8,
	cpus => 2, cpu_limit => 4, memory_mib => 1024, memory_limit_mib => 1536, max_memory_mib => 8192, description => '', bootmenu => 0,
	disks => [], interfaces => [], pools => [], volumes => [], networks => [] };
# Access supplies independent password and SSH forms beside hardware controls.
my $access_html = show_vm_access_tabs(show_vm_password_reset_form(
	{ uuid => 'guest', cloudmin => { username => 'cloudmin' } }, 'fixture-token'),
	'<form id="ssh-fixture"><input name="public"></form>');
my $stopped_editor = show_vm_edit_form($settings, 'fixture-token', 0, 0, 'resources', $access_html);
like($stopped_editor, qr/name="cpus"[^>]*>\s*<span\b[^>]*>out of 8<\/span>/,
	'editor shows the allowed CPU range as a note beside the input');
my ($start_form) = $stopped_editor =~ /(<form\b[^>]*id="vm-start-form".*?<\/form>)/s;
ok($start_form, 'stopped editor offers a separate Start form');
like($start_form, qr/name="action"[^>]*value="start"/, 'Start submits the power action');
like($start_form, qr/name="token"[^>]*value="fixture-token"/, 'Start carries the form token');
unlike($start_form, qr/name="(?:cpus|description)"|disabled=/,
	'Start is enabled and excludes pending edits');
unlike($stopped_editor, qr/id="vm-shutdown-form"/, 'stopped editor has no shutdown control');
like($stopped_editor, qr/form="vm-edit-form"/, 'Save remains attached to the editor');
# Running guests keep the editor and deletion confirmation available.
my $running_editor = show_vm_edit_form({ %$settings, active => 1,
	live_limits => { cpus => 4, min_cpus => 2, memory_mib => 1536, pcie_ports => 3 } }, 'fixture-token', 0, 0, 'access', $access_html);
like($running_editor, qr/id="vm-shutdown-form"/, 'running guest offers shutdown');
like($running_editor, qr/id="vm-edit-form"/, 'running guest has a hardware editor');
my ($delete_form) = $running_editor =~ /(<form\b[^>]*id="vm-delete-form".*?<\/form>)/s;
ok($delete_form, 'running editor offers deletion confirmation');
unlike($delete_form, qr/disabled=/, 'Delete stays enabled for running guests');
# Access forms are siblings of the hardware form, not nested within it.
foreach my $editor ($stopped_editor, $running_editor) {
	like($editor, qr/vm_edit_tabs.*access/s, 'editor offers the Access tab');
	unlike($editor, qr/vm-password-reset-review-form/, 'footer no longer links to a separate reset page');
	my ($reset) = $editor =~ /(<form\b[^>]*id="vm-password-reset-form".*?<\/form>)/s;
	like($reset, qr/name="action"[^>]*value="reset_password"/, 'Access contains the reset form');
	like($reset, qr/name="token"[^>]*value="fixture-token"/, 'password reset keeps its token');
	unlike($reset, qr/name="(?:cpus|public)"/, 'password reset does not submit hardware or keys');
	my ($hardware) = $editor =~ /(<form\b[^>]*id="vm-edit-form".*?<\/form>)/s;
	unlike($hardware, qr/name="(?:password|username|public)"/, 'hardware form excludes guest credentials');
	# Scan every form tag to catch invalid nesting across all Access panes.
	my $depth = 0;
	foreach my $tag ($editor =~ /(<\/?form\b[^>]*>)/g) {
		$depth += $tag =~ m{^</} ? -1 : 1;
		last if ($depth > 1 || $depth < 0);
		}
	is($depth, 0, 'forms are balanced and never nested');
	# Ignore script strings when checking the editor's actual div boundaries.
	my $markup = $editor;
	$markup =~ s{<(script|style)\b[^>]*>.*?</\1>}{}gs;
	$depth = 0;
	foreach my $tag ($markup =~ /(<\/?div\b[^>]*>)/g) {
		$depth += $tag =~ m{^</} ? -1 : 1;
		last if ($depth < 0);
		}
	is($depth, 0, 'editor div wrappers are balanced without stray closing tags');
	my @wrappers = $markup =~ /(<div\b[^>]*data-vm-edit-fields[^>]*>)/g;
	is(scalar(@wrappers), 3, 'each hardware tab has one field wrapper');
	like($_, qr/class="ui--div"/, 'hardware wrapper uses the tag API') foreach @wrappers;
	}
# An unavailable SSH tool falls back from a saved tab selection.
my $password_only = show_vm_access_tabs('password form', undef, 'ssh_keys');
like($password_only, qr/name="vm_access_tabs"[^>]*value="password"/, 'an unavailable SSH tool falls back to Password');
unlike($password_only, qr/tab_ssh_keys/, 'undefined SSH content omits its subtab');
{
	# Rendering nested tabs must not change the selected outer hardware tab.
	local $main::ui_tabs_selected = 'resources';
	show_vm_access_tabs('password', 'keys', 'ssh_keys');
	is($main::ui_tabs_selected, 'resources', 'nested Access tabs preserve the outer selection');
}
# Confirmation submits the guest name and history without a typing challenge.
my $delete_confirmation = show_vm_edit_form({ %$settings, active => 1, history_revision => 'history' }, 'fixture-token', 1);
like($delete_confirmation, qr/name="history_revision"[^>]*value="history"/, 'deletion submits the displayed snapshot history revision');
like($delete_confirmation, qr/type=['"]hidden['"][^>]*name="confirm_name"/, 'Delete submits the current name without asking the user to type it');
like($delete_confirmation, qr/name="shutdown"[^>]*value="1"/, 'confirmed deletion permits stopping the guest');
unlike($delete_confirmation, qr/Type the virtual machine name|Power will not be forced off|<b>Warning<\/b>/,
	'deletion omits the typed confirmation and extra warning');
like($delete_confirmation, qr/data-delete-stop-text/, 'deletion has a compact power-action note');
unlike($delete_confirmation, qr/id="vm-shutdown-form"|id="vm-force-off-review-form"/,
	'deletion confirmation does not redirect into manual shutdown');
# Explain the purpose of each disk without using its storage path as the heading.
my $explained_delete = show_vm_edit_form({ %$settings, name => 'fixture', disks => [
	{ target => 'vda', device => 'disk', role => 'system', path => '/system.qcow2',
	  volume_info => { capacity => 1024**3 } },
	{ target => 'vdb', device => 'disk', role => 'seed', readonly => 1, path => '/seed.iso' },
	] }, 'fixture-token', 1);
like($explained_delete, qr/System disk \(vda\).*?Contains the operating system/s,
	'system disk has a readable role and description');
like($explained_delete, qr/Cloud-init configuration \(vdb\).*?Read-only setup media/s,
	'seed explains its setup role');
like($explained_delete, qr/<details\b.*?Storage location.*?system\.qcow2/s,
	'full storage path is available in expandable details');
unlike($explained_delete, qr/data-delete-stop-text/, 'stopped guests have no shutdown note');
# Saved allocations can exceed live limits without disabling the form fields.
like($running_editor, qr/name="cpus"[^>]*data-vm-max="8"/, 'running editor allows saved CPU expansion');
like($running_editor, qr/name="cpus"[^>]*data-vm-min="1"/, 'running editor allows saving fewer boot CPUs');
like($running_editor, qr/name="memory_mib"[^>]*data-vm-max="8589934592"/, 'memory allocation can be saved above the running limit');
unlike($running_editor, qr/name="(?:cpu_limit|memory_limit_mib|boot|bootmenu)"[^>]*disabled/, 'maximums and boot settings stay editable');
unlike($running_editor, qr/id="vm-next-start-notice"/, 'running editor has no pre-save notice');
unlike($running_editor, qr/Shut down once/, 'guests with spare ports have no expansion warning');
my $pending_editor = show_vm_edit_form({ %$settings, active => 1,
    pending => {cpus => {running => 2, saved => 1}},
    live_limits => { cpus => 2, min_cpus => 2, memory_mib => 1536, pcie_ports => 3 } }, 'fixture-token', 0, 0, 'access', $access_html);
unlike($pending_editor, qr/name="cpus"[^>]*disabled/, 'CPU count remains editable when no live change is possible');
is(scalar(() = $pending_editor =~ /Running: 2, next start: 1/g), 1,
	'pending values appear only in the saved-changes alert');
unlike($pending_editor, qr/id="vm-next-start-notice"/,
	'the saved-changes alert replaces the bottom hint');
# Custom layouts lock only fields whose XML this editor cannot safely rewrite.
my $topology_editor = show_vm_edit_form({ %$settings, cpu_limit => 3,
	resource_locks => {cpu_limit => 1} }, 'fixture-token');
like($topology_editor, qr/name="cpu_limit"[^>]*disabled/, 'custom topology keeps the CPU maximum read-only');
like($topology_editor, qr/name="cpus"[^>]*data-vm-max="3"/, 'offline CPU count respects its topology maximum');
unlike($topology_editor, qr/name="(?:cpus|memory_mib)"[^>]*disabled/, 'topology leaves CPU count and memory editable');
like($topology_editor, qr/<div[^>]*>.*?The CPU maximum is fixed by the existing CPU layout/s,
	'topology note explains the affected field on its own line');
# Disabled required inputs retain hidden values for unrelated form saves.
my $device_editor = show_vm_edit_form({ %$settings,
	resource_locks => {cpus => 1, cpu_limit => 1, memory_mib => 1, memory_limit_mib => 1}}, 'fixture-token');
like($device_editor, qr/type=['"]hidden['"][^>]*name="cpus"[^>]*value="2"/, 'disabled CPU count is preserved in other form saves');
like($device_editor, qr/type=['"]hidden['"][^>]*name="memory_mib"[^>]*value="1024"/, 'disabled memory is preserved in other form saves');
like($device_editor, qr/type=['"]hidden['"][^>]*name="memory_mib_units"[^>]*value="1048576"/, 'preserved memory has explicit units');
# A requested shutdown has its own waiting view and emergency power-off link.
my $waiting_editor = show_vm_edit_form({ %$settings, active => 1 }, 'fixture-token', 0, 1);
my ($force_off_form) = $waiting_editor =~ /(<form\b[^>]*id="vm-force-off-review-form".*?<\/form>)/s;
like($force_off_form, qr/<form\b[^>]*action=['"]machine.cgi['"][^>]*method=['"]get['"]/,
	'active editor opens emergency confirmation with a separate GET form');
like($force_off_form, qr/name="force_off"[^>]*value="1".*name="return"[^>]*value="edit_machine"/s,
	'emergency confirmation retains its return to the editor');
like($force_off_form, qr/class=['"]ui_submit['"][^>]*value=['"]Force Power Off['"]/,
	'editor uses a standard submit for emergency confirmation');
like($waiting_editor, qr/id="vm-force-off-review-form"/, 'waiting editor keeps emergency control available');
# One editor submission collects device choices without submitting each tab.
my $edit = parse_vm_edit_form({
	id => 'guest', token => 'signed', action => 'update',
	disk_0_target => 'vda', disk_0_size => '2', disk_0_size_units => 1024**3,
	disk_1_target => 'vdb', disk_1_size => '9', disk_1_detach => 1,
	nic_0_mac => '52:54:00:00:00:01', nic_0_network => 'network:one',
	nic_1_mac => '52:54:00:00:00:02', nic_1_network => 'network:two',
	nic_1_remove => 1, add_disk_pool => 'pool', add_disk_size => '3',
	add_disk_size_units => 1024**3, attach_volume => 'pool:disk:one.qcow2',
	add_interface_network => 'bridge:br0',
});
is_deeply($edit->{'changes'}, [
	{ action => 'grow_disk', target => 'vda', disk_gib => '2', disk_gib_units => 1024**3 },
	{ action => 'detach_disk', target => 'vdb' },
	{ action => 'update_interface', mac => '52:54:00:00:00:01', network => 'network:one' },
	{ action => 'remove_interface', mac => '52:54:00:00:00:02' },
	{ action => 'add_disk', pool => 'pool', disk_gib => '3', disk_gib_units => 1024**3 },
	{ action => 'attach_disk', pool => 'pool', volume => 'disk:one.qcow2' },
	{ action => 'add_interface', network => 'bridge:br0' },
], 'all hardware choices become one ordered update; removal takes precedence');
is($edit->{'token'}, 'signed', 'combined form keeps its authentication token');
# Checkbox absence means disconnected only when the cable control was shown.
for my $connected (0, 1) {
	my $change = parse_vm_edit_form({ nic_0_mac => '52:54:00:00:00:01',
		nic_0_link_present => 1, ($connected ? (nic_0_link => 'up') : ()),
		nic_0_inbound_kib => 128, nic_0_outbound_kib => '' })->{'changes'};
	is_deeply($change, [{ action => 'update_interface', mac => '52:54:00:00:00:01',
		network => '', link => $connected ? 'up' : 'down',
		inbound_kib => 128, outbound_kib => '' }],
		'cable toggle submits '.($connected ? 'connected' : 'disconnected').' with bandwidth values');
	my $editor = show_vm_edit_form({ %$settings, interfaces => [{
		mac => '52:54:00:00:00:01', link => $connected ? 'up' : 'down' }] }, 'token');
	# Both toggle states need the presence marker to
	# distinguish omission from off.
	my ($input) = $editor =~ /(<input\b[^>]*name="nic_0_link"[^>]*>)/;
	like($input, qr/type="checkbox"/, 'cable state uses a toggle');
	is(scalar($input =~ /\bchecked\b/) || 0, $connected, 'toggle reflects the current cable state');
	like($editor, qr/name="nic_0_link_present"[^>]*value="1"/, 'unchecked cable can be submitted');
	}
is_deeply(parse_vm_edit_form({ nic_0_mac => '52:54:00:00:00:01' })->{'changes'}, [],
	'a missing cable control does not disconnect an interface');
is_deeply(parse_vm_edit_form({ nic_0_mac => '52:54:00:00:00:01',
	nic_0_remove => 1, nic_0_link_present => 1 })->{'changes'},
	[{action => 'remove_interface', mac => '52:54:00:00:00:01'}],
	'removal still takes precedence over the cable toggle');
is_deeply(parse_vm_edit_form({ disk_0_target => 'vda', disk_0_size => '',
	add_disk_size => '', attach_volume => '', add_interface_network => ''
	})->{'changes'}, [], 'blank optional controls change nothing');
is(parse_vm_edit_form({ add_disk_size => '0', add_disk_size_units => 1024**3
	})->{'changes'}->[0]->{'disk_gib'}, '0', 'zero is validated, not silently skipped');
# Only the selected disk action is submitted; leftover fields stay inactive.
my %disk_fields = (add_disk_pool => 'pool', add_disk_size => 3,
	add_disk_size_units => 1024**3, clone_disk_pool => 'pool', clone_image => 'image',
	attach_volume => 'pool:existing.qcow2');
for my $case (
	['none', []],
	['create', [{ action => 'add_disk', pool => 'pool', disk_gib => 3, disk_gib_units => 1024**3 }]],
	['clone', [{ action => 'add_disk', pool => 'pool', image => 'image' }]],
	['attach', [{ action => 'attach_disk', pool => 'pool', volume => 'existing.qcow2' }]],
) {
	is_deeply(parse_vm_edit_form({ %disk_fields, add_disk_action => $case->[0] })->{'changes'},
		$case->[1], 'disk action '.$case->[0].' excludes unselected fields');
	}
for my $case (['clone', 'clone_image'], ['attach', 'attach_volume']) {
	ok(!eval { parse_vm_edit_form({ %disk_fields, add_disk_action => $case->[0], $case->[1] => '' }); 1 },
		'empty '.$case->[0].' selection is refused');
	}
my $disk_editor = show_vm_edit_form({ %$settings,
	disks => [{target => 'vdb', device => 'disk', readonly => 1, role => 'seed', path => '/seed.iso'}],
	volumes => [{pool => 'pool', name => 'hidden-original.qcow2', format => 'qcow2'}],
	attachable_volumes => [{pool => 'pool', name => 'free.qcow2', capacity => 1024**3, pool_name => 'default'}],
	images => [{id => 'image', name => 'Original image', capacity => 1024**3, pool_name => 'default'}],
	}, 'token');
# Disk disclosures must work without a theme adding an accordion wrapper.
foreach my $panel ('add', 'remove') {
	like($disk_editor, qr/<details class="default default-lg vm-$panel-disk"><summary>.*?<\/summary>/,
		"$panel disk uses a closed native disclosure");
	}
unlike($disk_editor, qr/hiddenopener_vm_(?:add|remove)_disk/,
	'disk disclosures do not depend on theme-specific hidden tables');
like($disk_editor, qr/Cloud-init configuration/, 'seed disk has a readable role');
like($disk_editor, qr/>Read-only<\/span>/, 'seed exposes its read-only state as visible text');
unlike($disk_editor, qr/hidden-original/, 'raw inventory is not used for attachment choices');
like($disk_editor, qr/free\.qcow2 - 1 GiB \(default\)/, 'unused disk choice includes capacity and pool');
like($disk_editor, qr/Clone from image/, 'cloning is a separate action');
like($disk_editor, qr/<select\b[^>]*name="clone_image"[^>]*>.*?<option value="" selected>.*?<optgroup\b[^>]*label="Imported images"[^>]*>.*?value="image"/s,
	'clone selector uses shared grouping and keeps its unselected placeholder');
unlike($disk_editor, qr/[&?](?:amp;)?delete_disk=/, 'unmanaged disk has no delete action');
for my $imported (0, 1) {
	my $editor = show_vm_edit_form({ %$settings, disks => [{
		target => 'vda', device => 'disk', imported => $imported,
		volume_info => { pool_name => 'default', name => 'data.qcow2', path => '/data.qcow2', capacity => 1024**3 },
	}] }, 'token');
	# Reusable source images must not offer destructive disk controls.
	if ($imported) {
		unlike($editor, qr/[&?](?:amp;)?delete_disk=/, 'imported disk has no delete action');
		}
	# Ordinary managed disks can open their own deletion confirmation.
	else {
		like($editor, qr/<a\b[^>]*href=['"]edit_machine\.cgi\?id=[^'"&]+&(?:amp;)?vm_edit_tabs=disks&(?:amp;)?delete_disk=vda['"][^>]*>.*?Delete disk.*?<\/a>/s,
			'managed disk links to confirmation in the editor');
		}
	}
my $disk_confirmation = show_vm_delete_disk_form($settings, 'confirmation-token', {
	target => 'vda', volume_info => { name => '<data>.qcow2', path => '/pool/<data>.qcow2' } });
like($disk_confirmation, qr/<form\b[^>]*action=['"]edit_machine.cgi['"][^>]*method=['"]post['"]/,
	'disk confirmation posts to the editor');
like($disk_confirmation, qr/name="token"[^>]*value="confirmation-token"/,
	'confirmation keeps the signed form token');
like($disk_confirmation, qr/name="action"[^>]*value="delete_disk"/,
	'confirmation uses the disk deletion controller action');
unlike($disk_confirmation, qr/name="confirm_name"/, 'disk confirmation requires no typing');
like($disk_confirmation, qr/&lt;data&gt;\.qcow2/, 'confirmation escapes disk names');

my $vm_options = { capabilities => { cpus => 4, memory_kib => 8*1024**2,
	firmware => ['efi'] },
	images => [{ id => 'fixture', name => 'Ubuntu',
	virtual_size => 4*1024**3, pool_name => 'default' }],
	pools => [{ id => 'pool', name => 'default', available => 30*1024**3 }],
	networks => [{ key => 'network:test', name => 'default',
	type => 'network', forward => 'nat' }] };
# An explicit ISO selection exposes source-switch hooks without guest provisioning.
my $iso_form = show_vm_form({%$vm_options, images => [{id => 'installer',
    name => 'Setup', format => 'iso', virtual_size => 1024**3, pool_name => 'default'}]},
    {image => 'installer', install_source => 'iso'}, 'token');
like($iso_form, qr/name="install_source"/, 'creation exposes installation source');
like($iso_form, qr/value="iso"[^>]*selected[^>]*>Installer ISO/, 'explicit ISO selection keeps installer mode');
like($iso_form, qr/data-vm-image-source="iso"/, 'ISO choice carries its source type');
like($iso_form, qr/data-vm-cloud-init="1"/, 'cloud provisioning fields have a targetable group');
like($iso_form, qr/machine_create\.js/, 'creation loads source switching behavior');
# A clean host can create directly from the catalogue, including its default image.
my $catalogue_image = { id => 'catalogue:rocky-linux-10', catalogue_id => 'rocky-linux-10',
	name => 'Rocky Linux 10', architecture => 'aarch64', format => 'qcow2',
	url => 'https://example.test/rocky.qcow2', virtual_size => 10*1024**3 };
my $clean_options = {%$vm_options, images => [], catalogue_images => [$catalogue_image]};
my $clean_form = show_vm_form($clean_options, {}, 'token');
like($clean_form, qr/<form/, 'catalogue permits creation without imported images');
like($clean_form, qr/value="catalogue:rocky-linux-10"[^>]*selected/,
	'fresh default template selects Rocky Linux 10');
like($clean_form, qr/>Rocky Linux 10<\/option>/, 'catalogue image shows only its name');
# Distribution headings group versions together, independently of catalogue rank.
my $image_choices = get_vm_image_choices([
	{%$catalogue_image, os => 'Rocky Linux', release => '10'},
	{id => 'debian9', catalogue_id => 'debian9', name => 'Debian 9', os => 'Debian', release => '9'},
	{id => 'debian13', catalogue_id => 'debian13', name => 'Debian 13', os => 'Debian', release => '13'},
	{id => 'custom', name => 'Custom image', pool_name => 'default', virtual_size => 1024**3},
	{id => 'debian12', catalogue_id => 'debian12', name => 'Debian 12', os => 'Debian', release => '12', format => 'iso'}]);
is_deeply([map { $_->[0] } @$image_choices], ['debian13', 'debian12', 'debian9', 'catalogue:rocky-linux-10', 'custom'],
	'catalogue choices sort by distribution and descending version, followed by imports');
my $grouped_images = show_image_select('image', 'debian12', $image_choices, 0, 1);
like($grouped_images, qr/<optgroup\b[^>]*label="Debian"[^>]*>.*value="debian13".*value="debian12" selected.*value="debian9".*<\/optgroup>/s,
	'native distribution group contains its selected image');
like($grouped_images, qr/<optgroup\b[^>]*label="Rocky Linux"[^>]*>.*<optgroup\b[^>]*label="Imported images"[^>]*>/s,
	'other distributions and imports get separate headings');
like($grouped_images, qr/value="debian12" selected data-vm-image-source="iso"/,
	'grouped options retain source filtering metadata');
# Missing selections keep their name and source without invented import details.
for my $source (qw(cloud iso)) {
	my $missing = show_vm_form($clean_options,
		{image => 'missing-image', install_source => $source}, 'token');
	like($missing, qr{</optgroup>\s*<option\b[^>]*value="missing-image"[^>]*selected[^>]*data-vm-image-source="$source"[^>]*>Unavailable: missing-image</option>},
		'missing image stays selected outside groups, with no size or pool suffix');
}
my $escaped_group = show_image_select('image', '', [['unsafe', 'Image <name>', '', 'Family <name>']], 1);
unlike($escaped_group, qr/Family <name>|Image <name>/, 'custom names and group labels are escaped');
like($escaped_group, qr/disabled/, 'read-only grouped selector stays disabled');
# Hide cached duplicates unless a saved selection uses the import ID.
my $downloaded = { %{Cloudmin::Images::catalogue_request(
	{%$catalogue_image, id => 'rocky-linux-10'}, {})}, id => 'd'x32 };
my $cached_options = {%$clean_options, images => [$downloaded]};
is(scalar(@{get_vm_form_images($cached_options)}), 1, 'cached catalogue asset is not duplicated in the selector');
is(scalar(@{get_vm_form_images($cached_options, 'd'x32)}), 2,
	'an existing template referencing an import retains that explicit selection');
$cached_options->{'presets'} = {template => {entries => [{settings => {image => 'd'x32}}]}};
is(scalar(@{get_vm_form_images($cached_options)}), 2,
	'switching to an older template can still select its imported image by name');
my $vm_form = show_vm_form($vm_options, { name => '<unsafe>' }, 'fixture-token');
like($vm_form, qr/name="cpus"[^>]*>\s*<span\b[^>]*>out of 4<\/span>/,
	'creation shows the host CPU limit as a note beside the input');
# The form opens on the details section and summarizes the template and plan.
like($vm_form, qr/vm_details/, 'creation opens with the details section');
like($vm_form, qr/hiddendiv_vm_image.*hiddendiv_vm_resources.*hiddendiv_vm_access.*hiddendiv_vm_software.*hiddendiv_vm_network.*hiddendiv_vm_boot/s,
	'optional sections appear in the expected order');
unlike($vm_form, qr/vm_advanced/, 'the form has no combined advanced section');
# The accordions carry the cloud-init marker themselves, without a wrapper.
foreach my $section (qw(vm_access vm_software)) {
	like($vm_form, qr/<table\b[^>]*data-vm-cloud-init="1"[^>]*>(?:(?!<\/table>).)*?id=['"]hiddendiv_$section['"]/s,
		"the $section accordion hides as a whole in installer mode");
	}
unlike($vm_form, qr/<div\b[^>]*data-vm-cloud-init="1"[^>]*>\s*<table/,
	'no accordion is wrapped in a cloud-init div');
# Show allocations and software without needing to expand their sections.
like($vm_form, qr/Default Plan \(2 CPU, 2 GiB memory, 20 GiB disk\)/, 'plan options carry their allocations');
like($vm_form, qr/data-vm-chip="resources"[^>]*>.*?2 CPU, 2 GiB memory, 20 GiB disk/s, 'the summary chips restate the plan');
unlike($vm_form, qr/[^\x00-\x7f]/, 'the creation form stays ASCII, as Webmin pages expect');
like($vm_form, qr/data-vm-chip="software"[^>]*>.*?No extra software/s, 'the summary names the software choice');
# Keep identity and credentials before the template and plan selectors.
like($vm_form, qr/name=['"]name['"].*name=['"]hostname_set['"].*name=['"]hostname['"].*name=['"]password['"].*ui_table_hr.*name=['"]template['"].*name=['"]plan['"]/s,
	'identity fields precede credentials, a divider and the preset selectors');
# The hostname row stays hidden until the checkbox below the name reveals it.
my $folded_hostname = qr/<tr\b(?=[^>]*id='vm_hostname_row')(?=[^>]*\bhidden\b)[^>]*>/;
my ($hostname_toggle) = $vm_form =~ /(<input\b[^>]*name=['"]hostname_set['"][^>]*>)/;
unlike($hostname_toggle, qr/\schecked\b/, 'the hostname checkbox starts unticked');
like($vm_form, qr/<div\b(?=[^>]*data-vm-hostname-toggle="1")[^>]*>\s*<input\b[^>]*name=['"]hostname_set['"]/,
	'the checkbox sits in a wrapper the stylesheet can line up with the input');
like($vm_form, qr/\[data-vm-hostname-toggle\] \{ margin: 3px 0 0 1\.5px; \}/,
	'the wrapper margin rule is part of the form styles');
like($vm_form, $folded_hostname, 'the hostname row starts hidden');
unlike(show_vm_form($vm_options, { hostname => 'web.example.test' }, 'token'),
	$folded_hostname, 'a supplied hostname opens its row');
# A standalone required attribute, not the word inside the placeholder text.
my $required_attr = qr/\srequired(?=\s*>|\s+[\w-]+=)/;
my ($hostname_input) = $vm_form =~ /(<input\b[^>]*name=['"]hostname['"][^>]*>)/;
like($hostname_input, qr/placeholder="Blank to use virtual machine name"/,
	'the hostname placeholder explains the optional default');
unlike($hostname_input, $required_attr, 'the hostname stays optional without Virtualmin');
unlike($vm_form, qr/<(?:div|span)\b[^>]*data-vm-template-(?:note|desc)=/,
	'template descriptions are hidden by default');
my $template_notes = get_vm_form_defaults({machine_show_template_description => 1});
my $notes_template = (Cloudmin::Presets::builtin_presets('template'))[0];
my $notes_options = {%$vm_options, form_defaults => $template_notes,
	presets => {template => {default => $notes_template->{'id'}, entries => [$notes_template]}}};
like(show_vm_form($notes_options, {}, 'token'),
	qr/<span\b[^>]*data-vm-template-desc="1"[^>]*>Rocky Linux 10, password login/,
	'enabling descriptions shows text that differs from the name');
my $no_template_note = show_vm_form({%$vm_options,
	form_defaults => get_vm_form_defaults({machine_show_template_description => 0})}, {}, 'token');
unlike($no_template_note, qr/<(?:div|span)\b[^>]*data-vm-template-(?:note|desc)=/,
	'disabling template descriptions omits the container used by browser updates');
like($no_template_note, qr/name=['"]template['"]/, 'hiding descriptions keeps the template selector');
like($vm_form, qr/data-vm-license="1"/, 'license rows exist for Pro templates');
# A Pro template supplies the software summary without forcing a separate hostname.
my $pro_template = { id => 'c'x32, name => 'Virtualmin Pro with Nginx',
	description => 'Virtualmin Pro with Nginx', settings => {
	software => 'virtualmin-pro', virtualmin_bundle => 'LEMP', virtualmin_postgres => '1' } };
my $pro_form = show_vm_form({ %$vm_options, form_defaults => $template_notes,
	presets => { template => { default => $pro_template->{'id'},
	entries => [(Cloudmin::Presets::builtin_presets('template'))[0], $pro_template] } } }, {}, 'token');
like($pro_form, qr/data-vm-chip="software"[^>]*>.*?Virtualmin Pro with Nginx and PostgreSQL/s,
	'a Virtualmin template is summarized by edition, web server and PostgreSQL');
# The VM name remains the fallback even with Virtualmin selected by default.
my ($pro_hostname_input) = $pro_form =~ /(<input\b[^>]*name=['"]hostname['"][^>]*>)/;
like($pro_hostname_input, qr/placeholder="Blank to use virtual machine name"/,
	'Virtualmin templates retain the hostname fallback');
unlike($pro_hostname_input, $required_attr, 'Virtualmin templates leave the separate hostname optional');
my ($pro_toggle) = $pro_form =~ /(<input\b[^>]*name=['"]hostname_set['"][^>]*>)/;
unlike($pro_toggle, qr/\schecked\b/, 'Virtualmin templates leave the hostname checkbox unticked');
like($pro_form, $folded_hostname, 'Virtualmin templates leave the hostname row hidden');
# section_state(name, state) matches a section's rendered shown or hidden class.
my $section_state = sub { my ($name, $state) = @_;
	qr/<div\b(?=[^>]*id=['"]hiddendiv_$name['"])(?=[^>]*opener_$state)[^>]*>/ };
# Sections start open only through Module Configuration, regardless of presets.
like($pro_form, $section_state->('vm_software', 'hidden'),
	'Virtualmin templates leave the software section collapsed');
like($pro_form, $section_state->('vm_network', 'hidden'),
	'Virtualmin templates leave the network section collapsed');
like(show_vm_form($vm_options, { address_mode => 'static' }, 'token'),
	$section_state->('vm_network', 'hidden'), 'static addressing leaves the network section collapsed');
{
local $config{'machine_create_sections'} = 'network';
like(show_vm_form($vm_options, {}, 'token'), $section_state->('vm_network', 'shown'),
	'Module Configuration opens a section from the start');
}
like($pro_form, qr/<div\b(?=[^>]*data-vm-template-note="1")(?=[^>]*\bhidden\b)[^>]*>/,
	'a description that only repeats the template name is not shown');
# Always show keeps repeated descriptions visible, but leaves empty ones hidden.
my $always_notes = get_vm_form_defaults({machine_show_template_description => 2});
my $always_form = show_vm_form({%$notes_options, form_defaults => $always_notes,
	presets => {template => {default => $pro_template->{'id'}, entries => [$pro_template]}}}, {}, 'token');
like($always_form, qr/<div\b(?=[^>]*data-vm-template-note="2")(?![^>]*\bhidden\b)[^>]*>/,
	'Always show displays descriptions even when they repeat the name');
like($always_form, qr/<span\b[^>]*data-vm-template-desc="1"[^>]*>Virtualmin Pro with Nginx</,
	'the repeated description keeps its text');
my $empty_note_form = show_vm_form({%$notes_options, form_defaults => $always_notes,
	presets => {template => {default => $pro_template->{'id'},
	entries => [{%$pro_template, description => ''}]}}}, {}, 'token');
like($empty_note_form, qr/<div\b(?=[^>]*data-vm-template-note="2")(?=[^>]*\bhidden\b)[^>]*>/,
	'Always show still hides empty descriptions');
# Capacity hints must use host RAM and the chosen pool, including a full pool.
like($vm_form, qr/<span\b[^>]*data-vm-capacity="memory_mib"[^>]*>out of 8 GiB<\/span>/,
	'host memory in KiB is shown in readable units');
like($vm_form, qr/<span\b[^>]*data-vm-capacity="disk_gib"[^>]*>out of 30 GiB available<\/span>/,
	'disk hint shows available pool space');
my $pool_options = { %$vm_options, pools => [
	{ id => 'other', name => 'other', available => 0 }, @{$vm_options->{'pools'}} ] };
like(show_vm_form($pool_options, {}, 'token'),
	qr/<span\b[^>]*data-vm-capacity="disk_gib"[^>]*>out of 30 GiB available<\/span>/,
	'default pool capacity is used even when it is not the first option');
like(show_vm_form($pool_options, { pool => 'other' }, 'token'),
	qr/<span\b[^>]*data-vm-capacity="disk_gib"[^>]*>out of 0\b[^<]* available<\/span>/,
	'a selected full pool shows zero rather than the default capacity');
unlike($vm_form, qr/name=['"]description['"]/,
	'description is hidden by default');
like($vm_form, qr/<option\b[^>]*value=['"]password['"][^>]*selected/,
	'password authentication is selected by default');
my $vm_defaults = get_vm_form_defaults({ machine_show_description => 1,
	machine_generate_password => 1 });
# Access defaults come from the selected template; display policy stays global.
my $configured_template = (Cloudmin::Presets::builtin_presets('template'))[0];
@{$configured_template->{'settings'}}{qw(username auth_type)} = ('root', 'both');
my $configured_options = { %$vm_options, form_defaults => $vm_defaults,
	presets => {template => {default => $configured_template->{'id'}, entries => [$configured_template]}} };
my $configured_form = show_vm_form($configured_options, {}, 'token',
	'random-fixture-secret');
like($configured_form, qr/name=['"]description['"]/,
	'description can be enabled');
like($configured_form, qr/name=['"]username['"][^>]*value=['"]root['"]/,
	'template username is filled in');
like($configured_form, qr/<option\b[^>]*value=['"]both['"][^>]*selected/,
	'template authentication is selected');
is(scalar(() = $configured_form =~ /value=['"]random-fixture-secret['"]/g), 1,
	'generated password fills the single password field');
my $redisplayed = show_vm_form($configured_options,
	{ action => 'create', username => 'alice', auth_type => 'keys' },
	'token', 'do-not-regenerate');
unlike($redisplayed, qr/do-not-regenerate/,
	'returning to an existing form does not generate a replacement');
like($redisplayed, qr/name=['"]username['"][^>]*value=['"]alice['"]/,
	'entered username overrides the template');
like($redisplayed, qr/<option\b[^>]*value=['"]keys['"][^>]*selected/,
	'entered authentication overrides the template');
unlike(show_vm_form($vm_options, {}, 'token', 'generation-disabled'),
	qr/generation-disabled/,
	'disabled generation keeps password fields empty');
like(show_vm_form($vm_options, { description => 'Keep this' }, 'token'),
	qr/>Keep this<\/textarea>/,
	'a supplied description is editable even when hidden by default');
is_deeply(get_vm_form_defaults({ vm_auth_type => 'invalid',
	vm_username => 'nobody' }),
	get_vm_form_defaults({}),
	'old module access defaults no longer override the template');
ok(check_vm_username('root') && check_vm_username('alice'),
	'root and ordinary usernames are allowed');
ok(!check_vm_username('Bad Name') && !check_vm_username('sshd'),
	'invalid and reserved usernames are rejected');
like($vm_form, qr/New virtual machine details/, 'creation starts with the details section');
unlike($vm_form, qr/image_compatible|Custom image compatibility/,
	'compatibility has no manual override');
like($vm_form, qr/New virtual machine details.*Image and storage.*Resources.*Access.*Software.*Network.*Boot options/s,
	'details precede the image, resources, access, software, network and boot sections');
like($vm_form, qr/name=['"]vm_operation['"][^>]*value=['"]create['"]/,
	'form submits directly to creation');
like($vm_form, qr/<form[^>]*action=['"]setup_machine\.cgi['"]/, 'creation uses theme streaming');
unlike($vm_form, qr/name=['"]action['"]/, 'creation leaves the native form action accessible');
like($vm_form, qr/Create Virtual Machine/,
	'button creates the virtual machine');
unlike($vm_form, qr/Review VM settings/, 'no extra review step is shown');
like($vm_form, qr/id=['"]hiddendiv_vm_boot['"]/, 'boot settings have their own section');
like($vm_form, qr/name=['"]firmware['"]/, 'firmware remains selectable');
unlike($vm_form, qr/<unsafe>/,
	'entered values are escaped on validation errors');
like($vm_form, qr/name=['"]memory_mib_units['"]/,
	'memory uses Webmin unit selection');
like($vm_form, qr/name=['"]disk_gib_units['"]/,
	'disk uses Webmin unit selection');
like($vm_form, qr/name=['"]auth_type['"]/,
	'authentication has a standard choice control');
like($vm_form,
	qr/type=['"]password['"][^>]*name=['"]password['"]|name=['"]password['"][^>]*type=['"]password['"]/, 'initial password uses Webmin password input');
my $password_form = show_vm_form($vm_options,
	{ auth_type => 'password', password => 'never-echo-this' }, 'token');
unlike($password_form, qr/never-echo-this/,
	'redisplayed password fields never echo input');
my $sized_form = show_vm_form($vm_options,
	{ memory_mib => 1.5, memory_mib_units => 1024**3, disk_gib => 12800,
	  disk_gib_units => 1024**2 }, 'token');
like($sized_form, qr/name=['"]memory_mib['"][^>]*value=['"]1\.5['"]/,
	'GiB memory survives redisplay');
like($sized_form, qr/name=['"]disk_gib['"][^>]*value=['"]12\.5['"]/,
	'MiB disk redisplays at its actual GiB size');
# A source without images blocks creation, so its explanation sits in the
# initially open details section, hidden while the chosen source has images.
like($vm_form, qr/<div\b(?=[^>]*data-vm-source-empty="1")(?=[^>]*\bhidden\b)[^>]*>.*hiddendiv_vm_image/s,
	'the empty-source note starts hidden above the collapsed image section');
my $iso_only = show_vm_form({ %$vm_options, images => [
	grep { ($_->{'format'} || '') ne 'iso' } @{$vm_options->{'images'}} ] },
	{ install_source => 'iso' }, 'token');
like($iso_only, qr/<div\b(?=[^>]*data-vm-source-empty="1")(?![^>]*\bhidden\b)[^>]*>/,
	'an ISO source without ISOs shows the note before any script runs');
my $vm_empty = show_vm_form({ %$vm_options, images => [] }, {}, 'token');
unlike($vm_empty, qr/<form/,
	'missing images cannot submit an unusable creation form');
like($vm_empty, qr/Image Manager/, 'missing images explain the next step');
# The catalogue's selection links must target its own form, whose position in
# document.forms depends on whether the image table rendered a form of its own.
my $catalogue_entry = { catalogue_key => 'custom-x:aarch64', name => 'Entry',
	os => 'OS', release => '1',
	architecture => 'aarch64', format => 'qcow2',
	catalogue_origin => 'custom', enabled => 1 };
my $ready_job = { id => 'c'x32, state => 'ready', updated => time(),
	created => time(), name => 'Ready',
	pool => $pool->{'id'}, pool_name => 'default', format => 'qcow2',
	bytes => 1, volume => 'ready.qcow2' };
my $catalogue_page = show_images_page({ images => \@form_images, pools => [ $pool ],
	catalogue_entries => [ $catalogue_entry ] });
like($catalogue_page, qr/document\.forms\[1\]\.key/,
	'catalogue select-all targets its form when the image table has no rows');
my $catalogue_rows_page = show_images_page({ images => \@form_images,
	pools => [ $pool ],
	jobs => [ $ready_job ], catalogue_entries => [ $catalogue_entry ] });
like($catalogue_rows_page, qr/document\.forms\[0\]\.job/,
	'image select-all targets the image table form');
like($catalogue_rows_page, qr/document\.forms\[2\]\.key/,
	'catalogue select-all follows the image table form');
# Read-only users see inventory and sources without mutation controls.
my $readonly_page = show_images_page({ images => \@form_images, pools => [ $pool ],
	readonly => 1,
	jobs => [ $ready_job ], catalogue_entries => [ $catalogue_entry ] });
like($readonly_page, qr/Ready/, 'read-only users still see imported images');
unlike($readonly_page, qr/Delete Selected Images/,
	'read-only users get no deletion button');
unlike($readonly_page, qr/name=['"]job['"]/,
	'read-only image rows have no checkboxes');
unlike($readonly_page, qr/cloudmin-image-submit/,
	'read-only users get no import button');
unlike($readonly_page, qr/name=['"]key['"]/,
	'read-only catalogue rows have no checkboxes');
# Saved changes use a dedicated summary, with a separate signed POST action.
my $banner = show_vm_pending_banner({ name => '<guest>', uuid => 'fixture',
	active => 1, state => 'running', pending => { cpu_limit => { running => 2, saved => 3 } } }, 'token', 'edit_machine');
like($banner, qr/Saved\. 1 change is waiting/, 'pending summary uses singular count');
like($banner, qr/Running: 2, next start: 3/, 'summary compares both definitions');
# Initial server rendering must escape network names before live updates begin.
my $network_banner = show_vm_pending_banner({pending => {networks => {
	running => [{mac => '52:54:00:11:22:33', type => 'network', source => 'default'}],
	saved => [{mac => '52:54:00:11:22:33', type => 'bridge', source => '<bridge>'}] }}});
like($network_banner, qr/Network interface default.*Bridge &lt;bridge&gt;/s,
	'initial network warning names both attachments and escapes source text');
my $header = vm_header_status({state => 'running', pending => {cpus => {running => 1, saved => 2}}});
like($header, qr/Running.*Power cycle pending/s, 'header groups power and pending status');
my $button = vm_power_cycle_button({uuid => 'fixture', active => 1, pending => {cpus => {running => 1, saved => 2}}}, 'token', 'edit_machine');
like($button, qr/action=['"]machine.cgi['"].*name=['"]action['"][^>]*value=['"]power_cycle['"]/s, 'power cycle uses its own POST form');
like($button, qr/class=['"]ui_submit['"]/, 'power cycle uses the standard submit size');
my $edit_buttons = vm_edit_buttons({id => 'fixture', active => 1,
	pending => {cpus => {running => 1, saved => 2}}}, 'token');
like($edit_buttons, qr/id="vm-shutdown-form".*id="vm-power-cycle-form"/s,
	'power cycle follows shutdown in the bottom controls');
# Pending state controls visibility; read-only summaries never submit actions.
like(vm_power_cycle_button({uuid => 'fixture', active => 1, pending => {}}, 'token'),
	qr/id="vm-power-cycle-form" hidden/, 'power cycle stays hidden without saved changes');
unlike(show_vm_pending_banner({pending => {}}, undef), qr/<form/, 'read-only summaries have no action');
my $pending_row = get_vm_row({ %{$data->{'servers'}->[0]}, pending => {cpus => {running => 1, saved => 2}} });
like($pending_row->[1], qr/Power cycle pending/, 'VM list includes pending badge');
unlike($pending_row->[1], qr/<a[^>]*\shidden(?:\s|>)/, 'pending badge is visible when settings differ');
# Every VM-facing disk label uses the same role and exact device identifier.
{
my @disks = (
    {target => 'vda', role => 'system', device => 'disk', path => '/pool/long-system.qcow2'},
    {target => 'vdb', role => 'seed', device => 'disk', readonly => 1, path => '/pool/long-seed.iso'},
    {target => 'sda', role => 'cdrom', device => 'cdrom'},
    {target => 'vdz', device => 'disk', path => '/pool/external.qcow2'});
my $editor = show_vm_edit_form({%$settings, disks => \@disks}, 'token');
like($editor, qr{value="disk:vda"[^>]*>System disk \(vda\)</option>}, 'boot option names the system disk');
like($editor, qr{value="disk:vdb"[^>]*>Cloud-init configuration \(vdb\)</option>}, 'boot option names setup media');
like($editor, qr{value="disk:sda"[^>]*>CD\/DVD drive \(sda\)</option>}, 'boot option names an empty CD/DVD drive');
like($editor, qr{value="disk:vdz"[^>]*>Disk \(vdz\)</option>}, 'unknown disk has an honest generic name');
my $labels = vm_boot_labels({disks => \@disks});
# Initial pending text and individual deletion reuse the editor's disk names.
is(vm_pending_value('boot', [{device => 'disk', target => 'vdb'}], $labels),
    'Cloud-init configuration (vdb)', 'pending boot change uses the picker label');
is(vm_pending_value('boot', [{device => 'hd'}], $labels), 'Disks', 'legacy boot classes have readable names');
my $confirmation = show_vm_delete_disk_form($settings, 'token', {%{$disks[0]},
    volume_info => {name => 'long-system.qcow2', path => '/pool/long-system.qcow2'}});
like($confirmation, qr{System disk \(vda\).*?<details\b[^>]*><summary>Storage location</summary>.*?long-system.qcow2}s,
    'individual disk deletion uses the same label with a collapsed filename');
}

# Delegated navigation and controls must match the controller's permissions.
{
our %access;
no warnings 'redefine';
# get_status_config(vm, [reopen]) omits transport setup from permission UI checks.
local *get_status_config = sub { return '{}'; };
my $id = '11111111-2222-3333-4444-555555555555';
local %access = (admin => 0, vms => $id, power => 1);
my $vm = {uuid => $id, name => 'Assigned guest', active => 1,
	state => 'running', disks => [], interfaces => []};
# Ordinary power operators see their guest but no host or connection tools.
my @menu = get_menu_items([$vm], $id, 0, 1, 1);
my $links = join(' ', map { $_->{'link'} || '' } @menu);
like($links, qr/machine\.cgi/, 'operator can open VM details');
unlike($links, qr/machine_form|edit_machine|storage|networks|images|snapshots|jobs|remote_access|console|terminal|webminlog/,
	'operator navigation hides ungranted and host tools');
my $details = show_vm_details($vm, 'token');
like($details, qr/value="reboot"/, 'ordinary power controls are visible');
unlike($details, qr/(?:force_off|reset)=1|value="power_cycle"|data-vm-password-reset/,
	'ordinary power grant does not expose forced or durable operations');
# Forced controls are independent; they must not bring back ordinary actions.
$access{'power'} = 0; $access{'force'} = 1;
$details = show_vm_details($vm, 'token');
like($details, qr/force_off=1/, 'separate force permission shows force-off');
unlike($details, qr/value="reboot"|value="shutdown"|value="start"/,
	'force permission does not expose ordinary power controls');
# Password delegates can enter the editor without receiving hardware access.
$access{'force'} = 0; $access{'password'} = 1;
@menu = get_menu_items([$vm], $id, 0, 1, 0);
$links = join(' ', map { $_->{'link'} || '' } @menu);
like(un_urlize($links), qr/edit_machine\.cgi\?id=$id&vm_edit_tabs=access/,
	'password delegate enters only the reset form');
$details = show_vm_details($vm, 'token');
unlike($details, qr/password_reset|data-vm-password-reset|value="reboot"|force_off=1/,
	'password reset is absent from details and does not grant power controls');
# The reset form targets the editor and carries a token, never a saved password.
my $form = show_vm_password_reset_form($vm, 'signed-token');
like($form, qr/<form[^>]*action=['"]edit_machine\.cgi['"]/, 'password reset submits to the editor');
like($form, qr/name="action"[^>]*value="reset_password"/, 'reset form selects the API action');
like($form, qr/name="token"[^>]*value="signed-token"/, 'reset form carries the signed token');
my ($password_input) = $form =~ /(<input[^>]*name="password"[^>]*>)/;
like($password_input, qr/type=['"]password['"]/, 'password field is masked');
unlike($password_input, qr/value=['"][^'"]+/, 'reset form always starts with an empty password');
# Suggest the recorded creation account without restricting the editable field.
my ($username_input) = $form =~ /(<input[^>]*name="username"[^>]*>)/;
unlike($username_input, qr/value=['"][^'"]+/, 'missing creation metadata leaves the username blank');
my $recorded_form = show_vm_password_reset_form({ %$vm,
	cloudmin => { username => 'cloudmin' } }, 'signed-token');
($username_input) = $recorded_form =~ /(<input[^>]*name="username"[^>]*>)/;
like($username_input, qr/value=['"]cloudmin['"]/, 'reset suggests the recorded creation username');
unlike($username_input, qr/\b(?:readonly|disabled)\b/, 'suggested username remains editable');
# Discovered accounts use the shared switch widget, with manual entry as needed.
my $listed_form = show_vm_password_reset_form({ %$vm,
	cloudmin => { username => 'cloudmin' } }, 'signed-token', [qw(root cloudmin deploy)]);
like($listed_form, qr/<select[^>]*name="password_username"/, 'available accounts use a dropdown');
like($listed_form, qr/<option value="cloudmin" selected>/, 'creation account is selected even when not first');
like($listed_form, qr/<option value="">Other account\.\.\.<\/option>/, 'dropdown offers manual entry');
like($listed_form, qr/<div(?=[^>]*data-ui-switch-value="")(?=[^>]*hidden)[^>]*>/,
	'manual input starts hidden for a listed account');
my $other_form = show_vm_password_reset_form({ %$vm,
	cloudmin => { username => 'unlisted' } }, 'signed-token', ['root']);
like($other_form, qr/<option value="" selected>/, 'unlisted creation account selects Other');
like($other_form, qr/name="username"[^>]*value="unlisted"/, 'unlisted creation account stays editable');
unlike($other_form, qr/<div(?=[^>]*data-ui-switch-value="")(?=[^>]*hidden)[^>]*>/,
	'manual input is visible for an unlisted account');
my $discovered_form = show_vm_password_reset_form($vm, 'signed-token', [qw(deploy root)]);
like($discovered_form, qr/<option value="deploy" selected>/, 'missing metadata selects the first discovered account');
# Failed and empty discovery both retain the picker and the configured login.
for my $accounts (undef, []) {
	my $fallback = show_vm_password_reset_form({ %$vm,
		cloudmin => { username => 'cloudmin' } }, 'signed-token', $accounts);
	like($fallback, qr/<select[^>]*name="password_username"/,
		'unavailable accounts retain the dropdown');
	like($fallback, qr/<option value="cloudmin" selected>/,
		'unavailable accounts select the configured login');
	like($fallback, qr/<option value="">Other account\.\.\.<\/option>/,
		'unavailable accounts still offer manual entry');
	like($fallback, qr/<div(?=[^>]*data-ui-switch-value="")(?=[^>]*hidden)[^>]*>/,
		'manual entry starts hidden for the configured login');
	my $unknown = show_vm_password_reset_form($vm, 'signed-token', $accounts);
	like($unknown, qr/<option value="" selected>Other account\.\.\.<\/option>/,
		'no metadata or accounts selects manual entry');
	unlike($unknown, qr/<div(?=[^>]*data-ui-switch-value="")(?=[^>]*hidden)[^>]*>/,
		'manual entry remains visible without any known account');
	}
# Imported metadata must be escaped before it reaches the username field.
my $escaped_form = show_vm_password_reset_form({ %$vm,
	cloudmin => { username => '"><script>bad</script>' } }, 'signed-token');
unlike($escaped_form, qr/<script>/, 'creation username cannot inject markup into the reset form');
like($escaped_form, qr/<option value="" selected>/,
	'invalid configured login stays in manual entry for correction');
# A console grant exposes the shared Remote access link.
$access{'console'} = 1;
@menu = get_menu_items([$vm], $id, 0, 1, 0);
$links = join(' ', map { $_->{'link'} || '' } @menu);
like($links, qr/remote_access\.cgi/, 'granted console appears in navigation');
ok(!can_access('terminal', $id), 'console permission does not imply SSH');
}

# Empty inventories must retain creation without adjacent menu dividers.
{
our %access;
local %access = (admin => 1);
foreach my $readonly (0, 1) {
	my @menu = get_menu_items([], '', $readonly, 0, 0);
	my $types = join(' ', map { $_->{'type'} || '' } @menu);
	unlike($types, qr/\bhr\s+hr\b/, 'empty menu has no duplicate dividers');
	my @create = grep { ($_->{'format'} || '') eq 'link-new' } @menu;
	is(scalar(@create), $readonly ? 0 : 1,
		'empty menu respects creation permissions');
	}
}

done_testing();
