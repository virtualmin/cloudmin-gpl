# Example Cloudmin plugin functions

# plugin_desc()
# Must return a human-readable description of this plugin
sub plugin_desc
{
}

# plugin_check()
# Called when this plugin is being enabled, to check if it is usable on
# the current system. Must return an error message if not, or undef if OK.
# Optional - if missing, the check is assumed to be OK.
sub plugin_check
{
}

# server_actions(&server)
# Returns an array of additional links for some virtual system, each of which
# is a hash ref with the keys :
# id - A unique ID for this action
# desc - A human-readable description
# cat - The category code
# link - Relative URL for the link
# Optional - if missing, no links are added.
sub server_actions
{
}

# settings_links()
# Returns an array of additional links for global settings, each of which
# is a hash ref with the keys :
# icon - Path to an icon for the setting (optional)
# title - A human-readable description
# cat - The category code
# link - Relative URL for the link
# Optional - if missing, no links are added.
sub settings_links
{
}

