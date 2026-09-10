# Registry entries

These are the files to submit to the [DMS plugin registry][registry], one per
plugin. They are kept here so they stay in step with each plugin's own
`plugin.json` — the registry rejects an entry whose `id` or `name` disagrees
with the plugin it points at.

They are **not** plugins themselves; DMS ignores this directory because it holds
no `plugin.json`.

## Submitting

The registry holds only these descriptions. The plugins stay in this repository,
referenced by `repo` plus `path`, which is how the registry supports a monorepo.

```sh
gh repo fork AvengeMedia/dms-plugin-registry --clone
cd dms-plugin-registry
cp /path/to/DMS-Plugins/.registry/by-architect-*.json plugins/

python3 .github/generate.py --validate
python3 .github/validate_links.py

git checkout -b add-chat-plugins
git add plugins/by-architect-*.json
git commit -m "Add the Chats plugin and its providers"
gh pr create --title "Add Chats, its providers, and Chat Runner"
```

`validate_links.py` fetches every URL, so the screenshots have to exist and be
reachable before the checks pass.

## Screenshots

Each entry points at `<plugin>/docs/screenshot.png` in this repository. Capture
each plugin in a representative state — the chat window with a real conversation
open, the launcher mid-search — on the default theme.

[registry]: https://github.com/AvengeMedia/dms-plugin-registry
