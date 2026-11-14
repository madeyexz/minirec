# MiniRec

A minimal macOS menu-bar screen recorder for giving context to agents.

Press **⇧⌘7**, drag an area, press **Return** (or click Record). Press the shortcut again,
or click the red menu-bar icon, to stop. The file is copied to the clipboard, so you can
paste it into an agent, Slack, or Finder. Files are saved in `~/Movies/MiniRec`.

Settings (menu-bar icon › Settings…):

- **Record with ⇧⌘5**: turns off the macOS screenshot toolbar shortcut and uses ⇧⌘5
  instead of ⇧⌘7. Turn it off to give ⇧⌘5 back to macOS.
- **Export**: MP4 video, or image frames (JPEG, one every 0.5/1/2 s; frames that did not
  change are skipped). With frames, all the frame files are copied to the clipboard.
- **Resolution**: Standard (1×, smaller) or Retina.
- **Frame rate**: 15, 30, or 60 fps.
- **Show cursor**, **Record system sound**, and **Microphone** (None or a device). When
  both sound sources are on, they are mixed into one audio track.

MP4 is H.264 with a bitrate that scales with the area (at most 12 Mbit/s). A full-screen
scroll at 1× is about 7 MB per minute; a static screen is much less.

## Updates

MiniRec checks [GitHub Releases](https://github.com/madeyexz/minirec/releases) at launch
and once a day, and installs a new version when it is not recording. It installs only a
build signed with the same certificate as the installed copy. Menu-bar icon › Check for
Updates… checks now.

## Build

Needs macOS 15 or later and Xcode command line tools.

```sh
SIGN_IDENTITY="Apple Development: Your Name (ID)" ./scripts/build-app.sh
cp -R build/MiniRec.app /Applications/ && open /Applications/MiniRec.app
```

On the first recording, macOS asks for Screen Recording permission (and Microphone
permission if you chose one). Without `SIGN_IDENTITY` the build is signed ad hoc: macOS
asks again after each rebuild, and auto update is off.

## Release

```sh
SIGN_IDENTITY="Apple Development: Your Name (ID)" ./scripts/release.sh 0.2.0
```

This sets the version, builds, commits, tags, pushes, and creates a GitHub release with
`MiniRec.zip`. Use the same certificate for every release.
