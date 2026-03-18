@tool
extends GodotAIDock
class_name GodotAISurface

## Shared surface wrapper for dock + main-screen.
##
## This script should stay tiny: apply layout_variant tweaks only.
## All substantive behavior lives in `GodotAIDock` (wiring) and its helpers.

enum LayoutVariant { DOCK, MAIN_SCREEN }

@export var layout_variant: LayoutVariant = LayoutVariant.DOCK


func _ready() -> void:
	# Apply variant-specific layout tweaks before/after the base dock wiring.
	# Keep this file small; substantive logic stays in stores/helpers.
	super._ready()
	match layout_variant:
		LayoutVariant.DOCK:
			# Dock: let Godot dock system drive size; no extra margins.
			set_anchors_preset(Control.PRESET_FULL_RECT)
			set_offsets_preset(Control.PRESET_FULL_RECT)
		LayoutVariant.MAIN_SCREEN:
			# Main screen: ensure we always fill the editor main panel area.
			set_anchors_preset(Control.PRESET_FULL_RECT)
			set_offsets_preset(Control.PRESET_FULL_RECT)
			size_flags_horizontal = Control.SIZE_EXPAND_FILL
			size_flags_vertical = Control.SIZE_EXPAND_FILL
			custom_minimum_size = Vector2(520, 360)

