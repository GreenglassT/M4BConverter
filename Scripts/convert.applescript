#!/usr/bin/osascript
--  Drive M4B Converter from the command line.
--
--      osascript Scripts/convert.applescript "/Users/you/Audiobooks/Some Book"
--
--  The toolbar buttons are addressable by their accessibility description —
--  "Add Folder…" and "Convert All". Note `description`, not `name`: an
--  icon-only toolbar button has an empty AXTitle, so `name of button` returns
--  `missing value` and makes the control look unscriptable when it is not.
--
--  Requires Terminal (or whatever runs this) to hold Accessibility permission
--  in System Settings › Privacy & Security › Accessibility.
--
--  Known limitation: the footer's Cancel button is NOT addressable. It reports a
--  bare "button" with name, title and value all `missing value`, and adding
--  `.accessibilityLabel` to it changes nothing — verified by dumping the window's
--  accessibility tree before and after. To stop a run from a script, quit the app
--  instead: `osascript -e 'tell application "M4B Converter" to quit'`. That routes
--  through the same cancel path — measured at 0.37 s, with the ffmpeg children
--  reaped and the partial output deleted.

on run argv
	if (count of argv) is 0 then
		return "usage: convert.applescript <folder> [folder …]"
	end if

	tell application "M4B Converter" to activate
	delay 1

	repeat with folderPath in argv
		my addFolder(folderPath as string)
	end repeat

	my waitWhileScanning()
	my clickToolbar("Convert All")
	return "converting — watch the app for progress"
end run

on addFolder(folderPath)
	my clickToolbar("Add Folder…")
	delay 1.5
	tell application "System Events"
		tell process "M4B Converter"
			keystroke "g" using {command down, shift down}
			delay 1
			keystroke folderPath
			delay 0.8
			key code 36 -- Return: accept the path
			delay 1.2
			key code 36 -- Return: choose it
		end tell
	end tell
	delay 2
end addFolder

on clickToolbar(buttonDescription)
	tell application "System Events"
		tell process "M4B Converter"
			set target to (first button of toolbar 1 of window 1 ¬
				whose description is buttonDescription)
			if enabled of target is false then
				error "\"" & buttonDescription & "\" is disabled right now."
			end if
			click target
		end tell
	end tell
end clickToolbar

--  Adding a large library probes every file, so Convert All stays disabled
--  until the scan finishes. Clicking early would convert a partial list.
on waitWhileScanning()
	tell application "System Events"
		tell process "M4B Converter"
			repeat 300 times
				try
					if enabled of (first button of toolbar 1 of window 1 ¬
						whose description is "Convert All") then exit repeat
				end try
				delay 1
			end repeat
		end tell
	end tell
end waitWhileScanning
