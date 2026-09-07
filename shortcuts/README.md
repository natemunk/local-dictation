# Local Dictation iPhone Shortcut

- `Local Dictation.shortcut` — signed, importable shortcut. Contains placeholder token text only.
- `local_dictation.xml` — the same workflow as an editable XML plist.
- `build_local_dictation.py` — the generator. It imports `shortcut_builder` from Nate's
  `~/Shortcuts` toolkit; run it there (`python3 examples/local_dictation.py`) or point
  `sys.path` at that directory.

Rebuild after editing the XML with the toolkit's `./build.sh local_dictation.xml`, then copy
the result here. See [docs/iphone-shortcut.md](../docs/iphone-shortcut.md) for the install
steps and the request contract.
