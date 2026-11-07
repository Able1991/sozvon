# dmgbuild settings for Sozvon.dmg: the window people see when they open the DMG.
# Used by build.sh: dmgbuild -s packaging/dmg-settings.py -D app=<path to Sozvon.app> Sozvon <out.dmg>
# The layout is written into the image's .DS_Store directly, Finder is never scripted (works on CI).
import os.path

app = defines["app"]  # noqa: F821 (injected by dmgbuild)
# The settings file is exec()d without __file__: build.sh passes this folder too.
here = defines["here"]  # noqa: F821

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["Sozvon.app"]
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")  # the volume's icon

# The background is 660x400 points (with an @2x next to it); icon centers match tools/make_dmg_background.swift.
background = os.path.join(here, "dmg-background.png")
# Position: centered on a 1440x900 screen (Finder does not center it by itself). Height: 400 + the title bar.
window_rect = ((390, 230), (660, 432))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
icon_size = 112
text_size = 13
icon_locations = {"Sozvon.app": (170, 210), "Applications": (490, 210)}
