# dmgbuild settings: a small window, big icons, a custom background, the app's icon on the disk.
import os

app = defines.get("app", "dist/Strata Music.app")        # noqa: F821  (dmgbuild provides `defines`)
appname = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("volicon", "build/AppIcon.icns")      # noqa: F821
background = defines.get("bg", "build/dmg-bg.tiff")      # noqa: F821

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
window_rect = ((260, 160), (660, 400))
icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {appname: (170, 205), "Applications": (490, 205)}
