# Getting work back out

There are two ways out, for two situations, both running over the box's SSH
connection as a tar stream so the box *must be running*. When the agent is
untrusted, prefer `fetch`: it transfers only commit objects, which cannot carry
git hooks or editor task files, where `export` copies the whole working tree
including `.git`, so anything the agent planted there comes along and an exported
tree is worth reviewing before you run builds in it.

## `export`: copy the whole working tree

`isopod export <name> [dest]` copies the container's whole working tree (including
its `.git`) to a fresh host directory, and it will not write into an existing path
so the export shape stays predictable.

## `fetch`: pull only git history

`isopod fetch <name> [target-repo]` brings *only the committed git history* across,
with no file merges and no overwriting of your working tree.

```sh
cd ~/code/myproj          # an existing clone on your host
isopod fetch myproj        # target defaults to the current directory
```

Under the hood it `git fetch`es straight from the container over its SSH remote,
so the container's branches appear as remote-tracking refs named `<name>/*`
without touching your local branches. Check one out with:

```sh
git switch -c fingerprint-hardening myproj/my-branch-name
```

`isopod fetch` finds the repo at the container's workspace automatically (or the
single git subfolder inside it), and you can pass `--path <in-container-repo>` if
your layout is unusual. If the target isn't a git repo it drops an
`isopod-<name>.bundle` file instead and prints how to use it, and like `export` it
needs no network and no git remote.

## Rewriting git logs

Commits made inside a sandbox often carry a throwaway identity (`dev@<container>`),
and after a `fetch`, `isopod remap <name>` rewrites those commits to your real
name/email while preserving messages and dates. The rewrite is scoped to the
container's `<name>/*` refs (your own branches are never touched), only commits
matching the old identity are changed, and the originals are backed up under
`refs/remap-backup/`:

```sh
isopod remap myproj --name "Ada Lovelace" --email ada@example.com
```

The new identity defaults to your host `git config`, and identity resolution,
multi-identity remap files, undo, and the rewrite backends are covered in
**[docs/remap.md](remap.md)**.
