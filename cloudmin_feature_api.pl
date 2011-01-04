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

# owner_modules(&owner)
# Returns a list of additional modules this owner should be granted access to
sub owner_modules
{
}

# show_owner_inputs(&owner, new)
# Returns HTML for fields on the Edit System Owner page for additional
# restrictions this plugin defines
sub show_owner_inputs
{
}

# parse_owner_inputs(&owner, new, &in)
# Updates an owner object with inputs from show_owner_inputs. May call error
# if something invalid was entered.
sub parse_owner_inputs
{
}

# list_owner_fields(&owner, new)
# Returns an array of fields that can be set for an owner via the command
# line, each of which is a hash ref with keys :
# id - A unique ID for this field
# desc - Human-readable description
# value - Current value
# vdesc - Description of the value units or type
sub list_owner_fields
{
}

# save_owner_fields(&owner, new, &fields)
# Update a system owner with a list of fields, in the same format as
# returned by list_owner_fields. Returns an error message on failure, or
# undef on success.
sub save_owner_fields
{
}

# show_plan_inputs(&plan, new)
# Returns HTML for fields on the Edit Plan page for additional
# restrictions this plugin defines
sub show_plan_inputs
{
}

# parse_plan_inputs(&owner, new, &in)
# Updates a plan object with inputs from show_plan_inputs. May call error
# if something invalid was entered.
sub parse_plan_inputs
{
}

# list_plan_fields(&owner, new)
# Returns an array of fields that can be set for a plan via the command
# line, each of which is a hash ref with keys :
# id - A unique ID for this field
# desc - Human-readable description
# value - Current value
# vdesc - Description of the value units or type
sub list_plan_fields
{
}

# save_plan_fields(&owner, new, &fields)
# Update a plan with a list of fields, in the same format as
# returned by list_plan_fields. Returns an error mesage on failure
# or undef on succes.
sub save_plan_fields
{
}

# apply_owner_plan(&plan, &owner)
# Update a system owner with limits from a plan
sub apply_owner_plan
{
}

# replication_dirs()
# Returns a list of directories that should be replicated to other Cloudmin
# master systems. Any files within those directories will also be copied.
sub replication_dirs
{
}

# replication_files()
# Returns a list of files that should be replicated to other Cloudmin master
# systems.
sub replication_files
{
}
