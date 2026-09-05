# Handover: `feature/linux-task-sequences`

Written 2026-09-05 for the next agent. Craig is starting a fresh session so the
work does not cross over. Read this, then `AGENT_NOTES.md` - the section
**"Linux task sequences, 2026-09-05"** is the design record and this is only the
state of play.

---

## 1. Where you are

Branch `feature/linux-task-sequences`, two commits on top of `main` (`bb28b06`):

```
097f5f0  Task sequences know which installer reads them: Windows or Debian   <- mine
0ff24ee  Linux ISO boot: work in progress, committed as found                <- Craig's
bb28b06  (main) tools: bundled tools report their real version
```

**`0ff24ee` is not my work.** The Linux ISO boot work - ISO mount and serve, the
Debian netboot initrd match, `scripts/test-linux-iso-boot-qemu.sh`,
`sidecar/pxe/README.md` and its AGENT_NOTES section - was sitting *uncommitted*
in the working tree on `feature/linux-iso-boot` when I branched. I swept it into
my own commit by using `git add -A`, then split it back out into its own commit
so it stays attributable. Content untouched, but **check it is what Craig
expects before building on it**, and note that `feature/linux-iso-boot` itself
has no commits beyond `main` - everything was in the working tree.

Nothing is pushed. There is no remote branch.

Working tree is clean. All gates pass:

```
test-task-sequence-debian     22 checks
test-task-sequence-library    32 entries
test-task-sequence-accounts
test-strictmode-shapes
test-ascii                    257 files
tsc --noEmit                  clean
```

---

## 2. What was built

A task sequence now carries `platform`: `windows` (unattend.xml, unchanged) or
`debian` (a d-i preseed). Absent means `windows`, so every sequence saved before
this keeps working. `kind` - the client/server role - is cleared on a preseed
because it is a Windows concept.

| Where | What changed |
| --- | --- |
| `sidecar/lib/PxeBootTaskSequences.ps1` | `platform` on the record; `Build-AppPxeBootTaskSequencePreseed`; `Build-AppPxeBootTaskSequencePreseedLateCommand`; `ConvertTo-AppPxeBootTsShellSingleQuoted`; publish writes `<id>.cfg` (LF only) beside `<id>.xml`; prune and the default-sequence check learned about `.cfg` |
| `app/src/lib/types.ts` | `platform?` on `PxeBootTaskSequence` |
| `app/src/workspaces/PxeWorkspace.tsx` | Debian field labels, order and defaults; `tsPlatform` / `tsFieldOrder` / `tsFieldLabel`; a platform select on the create row; the list shows the platform for a preseed |
| `scripts/test-task-sequence-debian.ps1` | New gate, 22 checks |

The worked example throughout is **CampusCast** - Craig's other project, a
Debian digital-signage receiver that installs unattended and then runs one
script at first boot. Its real preseed is at
`/Volumes/Data/projects/CampusCast/receiver/preseed/` and is the model for the
`late_command` pattern here.

---

## 3. The four things that make Linux different

These are not incidental; every one of them shaped the code.

1. **Selection happens at boot, not after it.** WinPE shows a picker and copies
   the chosen XML to `Panther`. d-i is told `preseed/url=` on the kernel command
   line, so the **PXE menu entry** decides which sequence a machine gets.
2. **There is no deploy-time client.** The `{{SITE}}`/`{{SERIAL}}` half of the
   Windows token model has no counterpart; everything is concrete at publish
   time and anything per-machine is shell in `late_command`.
3. **Secrets cannot be withheld.** The Windows publisher deliberately leaves
   `{{JoinPw}}` for the client to fill so a join password never lands on the
   share. An unauthenticated installer fetching a preseed over HTTP cannot do
   that. Passwords go in as crypt(3) hashes; nothing else sensitive goes in.
4. **No mirror block in the preseed.** The menu already points d-i at the
   mounted ISO with `mirror/http/*`. Repeating it in the preseed overrides those
   kernel arguments and sends the installer to the internet instead of the ISO.

---

## 4. Next, in order

1. **Write `preseed/url=` into the Linux menu entries.** This is the piece that
   makes the feature real, and it is not done. It belongs in
   `Add-AppPxeBootDebianInstallerKernelArgs` (`sidecar/lib/PxeBootPlugin.ps1`,
   near the `mirror/http/*` it already injects). Add `auto=true
   priority=critical` at the same time, or d-i starts asking questions before it
   fetches the preseed.
   **Decide the shape first:** one menu entry per ISO x sequence, or one entry
   per ISO with a submenu. With 8 sequences and 3 ISOs the flat form is 24
   entries.
2. **Serve the first-boot script.** `runScriptUrl` is free text today. It should
   be a file in the library served over the existing Caddy tree, the way
   everything else is.
3. **Verify end to end in QEMU.** `scripts/test-linux-iso-boot-qemu.sh` already
   boots a Debian netinst; the missing tier is an install that consumes a
   generated preseed and lands a working machine. Nothing here has touched real
   hardware or a real installer.
4. **Ubuntu and RHEL**, if wanted. Each is another `platform` value and another
   builder; the store, publish and panel gating already take one.

---

## 5. Traps, so you do not pay for them again

**Quote at two levels in `late_command`, and do not trust a substring test.**
The fetch line quotes the URL for the shell inside `sh -c`, then quotes the
whole payload again for the shell reading the late_command line. Getting only
the outer level right still produces a *correct command* for an ordinary URL,
because adjacent quoted strings concatenate - so `sh -n` passes and so does
every regex for `wget ...`. It only comes apart on a space or a metacharacter.
That is why the gate executes the command with `in-target`, `wget`, `chmod` and
`systemctl` stubbed and asserts the URL arrives as one argument. I asserted the
old form was broken before checking; it was fragile, not broken, and the
difference mattered.

**`in-target` cannot be a shell function.** A hyphen is not valid in a POSIX
function name, so the test stubs are real executables placed on `PATH`.

**Preseeds must be LF.** d-i takes a CR as part of the value, so a CRLF hostname
is one nobody can resolve. The publish step strips CR for `debian` and adds it
for `windows`.

**`Get-Content` on a one-line file returns a scalar**, which has no `.Count`
under StrictMode. Wrap in `@()`. Same for `Where-Object` returning one item.

**PowerShell `"$var:..."`** parses the colon as part of a drive-qualified
variable. Use `"${var}:..."`.

**`$host` is read-only** and `Invoke-WebRequest` returns `byte[]` for
`octet-stream` - both already in AGENT_NOTES from the ISO work, both still true.

**Do not run the gates while a boot test is in flight.**
`scripts/test-strictmode.ps1` spawns a real sidecar, which adopts the running
Caddy and restarts it from its own empty mount map, and every `/iso-mount/`
route vanishes. Also in AGENT_NOTES; worth repeating because it looks like a
Caddy bug.

**Check `git status` before `git add -A`.** That is how Craig's uncommitted work
ended up in my commit.

---

## 6. Ground rules that held up

- **Verify on the target, not by reading.** On CampusCast, a macOS installer
  that looked correct for weeks produced four defects in its first ten minutes.
- **"Registered" is not "running".** `launchctl print` reports a crash-looping
  job as loaded; `Get-ScheduledTask .State` has the same weakness. Check the
  thing works, not that it exists.
- **A test that cannot fail is not a test.** Reintroduce the bug and watch the
  gate go red before you keep it. The quoting check here only earned its place
  on the second attempt.
- **One renderer, one source of truth.** Where CampusCast needed a preview it
  serves the receiver's own page rather than a lookalike; a second
  implementation agrees with the first for about a week.
