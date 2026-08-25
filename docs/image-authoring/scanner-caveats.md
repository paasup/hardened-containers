# Do not take scanner output or tags at face value

Detail behind [image-authoring/](README.md).

## Do not take scanner output at face value

Trusting trivy output directly has three failure modes. The gate
(`scripts/gate/image-gate.py`) is built to catch them.

| Mode | What happens |
| --- | --- |
| **Vendor downgrade** | The same CVE is rated differently per distribution — something NVD scores 9.8 may be LOW or MEDIUM to a distribution |
| **Missing data coverage** | When the scanner has no data for a distribution, the result looks exactly like zero findings — a false clean |
| **Unevaluated by vendor** | A CVE the distribution has not assessed yet ("Needs evaluation") is not reported by the scanner at all |

The first is caught by `effective_severity = max(vendor, NVD)` in `image-gate.py`. The
second is caught by the coverage self-check (`CoverageProbe`) in `scan-image.sh`. The
third is out of scope for this repository's slim gate — CVEs a vendor has not yet
evaluated are not cross-checked separately.

The `CoverageProbe` sentinel packages are deliberately **not** produced by lowering the
version of an installed package. If the only packages in the install list happen to have
no vendor advisories at all, lowering their versions still yields zero findings, and
"no data" would be misdiagnosed. The sentinels must be independent of what is installed.

## Confirm the base OS behind an image tag

For the same application version, different tags can carry different base operating
systems, and some of those may be close to end of life. If an operator ships a
distribution lifetime table, it shows up in the startup log — for example CNPG's
`internal/cmd/manager/instance/run/osdb.go`.
