# Blackmagic DeckLink SDK 16.0 (macOS headers)

Unmodified files from `Blackmagic DeckLink SDK 16.0/Mac/include`, used by
`Sources/KuhtakeDeckLink/KTDeckLink.mm` to capture Blackmagic
DeckLink/UltraStudio inputs directly (not through the Desktop Video camera
extension). Only `DeckLinkAPIDispatch.cpp` is compiled; it loads the
installed `/Library/Frameworks/DeckLinkAPI.framework` at run time.

Redistributed under the license at the top of each file. The SDK itself:
https://www.blackmagicdesign.com/desktopvideo_sdk (EULA:
https://www.blackmagicdesign.com/EULA/DeckLinkSDK).

To update: replace these files with the same ones from a newer SDK.
