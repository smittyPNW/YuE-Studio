"""Finder layout for the community disk image (dmgbuild 1.6.7)."""
from pathlib import Path

stage = Path(defines["stage"])
app = stage / "YuE Studio.app"
files = [str(app), str(stage / "Getting Started.html")]
symlinks = {"Applications": "/Applications"}
icon = str(app / "Contents/Resources/AppIcon.icns")
background = str(stage / "background.png")
format = "UDZO"
filesystem = "HFS+"
window_rect = ((160, 140), (660, 500))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
icon_size = 80
text_size = 13
label_pos = "bottom"
icon_locations = {
    "YuE Studio.app": (175, 210),
    "Applications": (485, 210),
    "Getting Started.html": (330, 355),
}
# Do not set FinderInfo on the signed app: that invalidates strict verification.
hide_extensions = ["Getting Started.html"]
