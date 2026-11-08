# Shared capture form and GPL preview use native Webmin controls.
use strict;
use warnings;
our %text;

# show_vm_image_form(source, token, [preview]) renders the image capture form.
# source contains the source revision, disk size and destination pool choices.
# preview defaults to false; true disables capture and accepts an empty token.

sub show_vm_image_form
{
my ($source, $token, $preview) = @_;
my @pools = @{$source->{'options'}->{'pools'}};
my $pool = $source->{'pool'} || (@pools ? $pools[0]->{'id'} : '');
# Bind an enabled submission to the source revision and form token.
my $form =
	ui_form_start('image_machine.cgi', 'post', undef, 'id="vm-image-form"').
	ui_hidden('token', $token).ui_hidden('id', $source->{'id'}).
	ui_hidden('revision', $source->{'revision'}).ui_hidden('vm_operation',
							       'capture_image');
# Disable preview fields natively, independent of the active theme.
$form .= ui_tag_start('fieldset',
		      { disabled => undef,
			'data-pro-disabled' => 'image-capture-elem',
			style => 'border:0;padding:0;margin:0;min-width:0' })
	if ($preview);
# Show the minimum disk capacity for virtual machines made from this image.
$form .= ui_table_start(undef, 'width=100%', 4);
$form .= ui_table_row(hlink($text{'vm_image_name'}, 'image_machine_name'),
		      ui_textbox('name', substr($source->{'name'}, 0,
						57).'-image', 40));
$form .= ui_table_row(hlink($text{'images_storage'}, 'image_machine_storage'),
		      ui_select('pool', $pool, [ map { [ $_->{'id'},
							 $_->{'name'} ] } @pools ]).
		      ui_p(text('vm_image_min_disk',
				nice_size_text($source->{'disks'}->[0]->{'bytes'}))));
# Default to removing login credentials and keeping the source running.
$form .= ui_table_row(hlink($text{'vm_image_clean_credentials'},
			    'image_machine_identity'),
		      ui_yesno_radio('clean_credentials', 1));
$form .= ui_table_row(hlink($text{'vm_image_preparation'},
			    'image_machine_preparation'),
		      ui_select('shutdown', 0,
				[ [ 0, $text{'vm_image_agent'} ],
				  [ 1, $text{'vm_image_shutdown'} ] ]));
$form .= ui_table_end();
# The submit button is outside the preview fieldset, so disable it separately.
$form .= ui_tag_end('fieldset') if ($preview);
$form .= ui_form_end([ [ undef, $text{'vm_image_title'}, undef, $preview
	? 1
	: 0 ] ]);
return $form;
}

1;
