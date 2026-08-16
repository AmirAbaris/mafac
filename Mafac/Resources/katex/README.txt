KaTeX assets — TODO before Phase 0's render pipeline actually works
====================================================================

This directory intentionally does NOT contain the KaTeX distribution.
The build/dev environment this project was scaffolded in has no network
access, so the following files could not be downloaded automatically.
Everything in the Swift/HTML layer (MathRenderView, katex-shell.html)
is already wired to expect them here — you just need to drop them in.

What to add, right in this directory (Mafac/Resources/katex/):

    Mafac/Resources/katex/katex.min.css
    Mafac/Resources/katex/katex.min.js
    Mafac/Resources/katex/fonts/               (the whole fonts/ folder)

Where to get them:

    1. Go to https://github.com/KaTeX/KaTeX/releases
    2. Download the latest release's "katex.tar.gz" (or .zip) asset
       — NOT the source code archive, the prebuilt "katex" distribution
       asset that already contains katex.min.js/css and fonts/.
    3. Unpack it and copy these three items into this directory:
         katex.min.css
         katex.min.js
         fonts/  (entire folder — katex.min.css references these by
                  relative path for glyph fallback rendering)
    4. You do NOT need katex.min.mjs, the auto-render extension, or any
       of the other language/locale files for Phase 0. (auto-render.min.js
       would be useful later if you switch to scanning raw text for $...$
       instead of calling katex.render() directly from Swift, but the
       current design calls KaTeX's render function explicitly per math
       block, so it isn't needed.)

You do NOT need to touch the Xcode project to add these files. In
project.pbxproj this whole "katex" directory is already added as a
*folder reference* (a blue folder in the project navigator, not a
yellow group) pointing at Mafac/Resources/katex — anything you copy
into this directory on disk is automatically included in the app
bundle's Resources at build time, preserving this folder's structure
(so it ends up at Mafac.app/Contents/Resources/katex/...). Just copy
the files in with Finder/Terminal and rebuild.

Once that's done, MathRenderView's WKWebView will load katex-shell.html
from Resources/katex/, which references ./katex.min.css and
./katex.min.js by relative path within that same folder — no further
code changes should be needed for the Phase 0 exit criterion (rendering
the hardcoded quadratic formula test equation) to work.

If it still shows a blank/placeholder view after that, open the project
in Xcode and confirm the "katex" blue folder reference under
Mafac/Resources still points at this directory (it can go stale if the
folder gets renamed or moved outside Xcode) and that it's listed in the
target's Build Phases -> Copy Bundle Resources.
