# dmgbuild settings for the installer image. dmgbuild writes the Finder
# layout (.DS_Store) itself, so no AppleScript and no Finder session is
# needed; that is what makes it work on a CI runner. Invoked by
# scripts/make-dmg.sh, which passes `app` in through -D.
import os.path

app = defines["app"]  # noqa: F821 (injected by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {app_name: (165, 190), "Applications": (495, 190)}

# Same 660x400 as the background. The window origin is where Finder opens
# it; the second pair is the size.
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

# make-dmg.sh runs from the repo root, so this is relative to that.
background = "scripts/dmg/background.tiff"
arrange_by = None
icon_size = 128
text_size = 13
show_icon_preview = False
include_icon_view_settings = "auto"
include_list_view_settings = "auto"
