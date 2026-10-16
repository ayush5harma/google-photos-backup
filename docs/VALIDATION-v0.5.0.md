# v0.5.0 preview validation

Checked on 16 October 2026. These results describe a preview; v0.4.0 remains the published release.

| Check | Result |
| --- | --- |
| Mac connected iPhone import | Disposable HEIC imported through the app; uploaded original matched all 769,010 bytes and SHA-256. |
| Windows connected Pixel import | Production portable-storage scan and staging passed; one synthetic PNG uploaded and its Google original matched all 329 bytes and SHA-256. |
| Windows connected iPhone import | The same disposable HEIC staged correctly; Google recognized the existing item and a fresh original download matched all bytes and SHA-256. |
| Windows long paths | 55 targeted native tests passed, including two real paths longer than 260 characters. Fresh Google original verification also passed against the Pixel fixture at a 263-character source path. |
| Android folder selection and album mirroring | Signed preview installed with matching certificate; 20 debug instrumentation tests passed on the Pixel, including compact-width and 200% text geometry. The owner confirmed successful real folder backup and the correct Google Photos album/test PNG. The Start backup layout defect confirmed through scrcpy is fixed; all focused layout tests pass. The signed update was installed and its full Backup screen verified through scrcpy, with the existing account and confirmed items retained. |
| iCloud reclaim | Automated checks pass; live disposable-fixture deletion/recovery validation pending. |

The Windows checks invoked the actual production device source, stager, backup coordinator and packaged bridge through a private CLI harness. They do not establish a live GUI click-through test; the available Parallels UI control failed. The harness used isolated backup state and existing sign-in without changing production history or settings. All source photos were retained.

Live testing found and fixed inaccessible MTP child folders, repeated iPhone device objects, and Python access to long Windows paths. Inaccessible entries produce an incomplete-list warning. Duplicate objects are identified by device object ID, not filename. The long-path fix preserves IDs, filenames and album names without changing Windows global policy.

Evidence commits: Windows device source `dd5786b`; long-path bridge `66bf189`; duplicate-object fix `c77f333`. Windows ARM64 and x64 checks passed for the integrated `a946aed` preview, including the duplicate-object regression and installer verification.

These finite tests verify the named fixtures and behavior. They do not guarantee future Google Photos quota treatment or arbitrary-device compatibility. Upstream credits are listed in [Acknowledgements](../ACKNOWLEDGEMENTS.md).
