# dmgbuild settings for MiniRec.dmg: the app, an Applications link, and an arrow between them.
# make-dmg.sh passes the app and background paths with -D.
files = [defines["app"]]  # noqa: F821
symlinks = {"Applications": "/Applications"}
icon = "Resources/AppIcon.icns"
format = "UDZO"

background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (600, 428))  # the 600 x 400 background plus the title bar
icon_size = 128
text_size = 13
icon_locations = {"MiniRec.app": (150, 190), "Applications": (450, 190)}
hide_extensions = ["MiniRec.app"]
