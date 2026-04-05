# Cloudflare Provider — CEL Bug Fix & Self-Hosted xpkg

**Created:** 2026-04-03
**Status:** Abandoned — wildbitca fork has multiple unfixable CRD generation defects. Waiting for official crossplane-contrib release.
**Goal:** Publish a patched Crossplane Cloudflare provider to GHCR and enable it in the platform.

---

## Background

No production-ready Crossplane Cloudflare provider xpkg exists:

| Repo | Problem |
|------|---------|
| `crossplane-contrib/provider-upjet-cloudflare` | Official successor — 251 CRDs, actively maintained, but **no versioned release published** |
| `wildbitca/provider-upjet-cloudflare` | Published v0.1.0/v0.2.0 xpkg — but has an invalid CEL rule that crashes provider install |
| `crossplane-contrib/provider-cloudflare` | Archived |
| `cdloh/provider-cloudflare` | Abandoned since 2024 |

**Plan:** Fork `wildbitca/provider-upjet-cloudflare`, fix the CEL bug in 4 CRD files, publish to `ghcr.io/stanleyxie/provider-upjet-cloudflare:v0.1.0-patched`.

---

## The CEL Bug

wildbitca v0.1.0 contains an invalid CEL validation rule in 4 CRD files. The `value` field in these CRDs is genuinely polymorphic — it can be a string, boolean, integer, or object depending on the Cloudflare zone/hostname setting. This is represented as:

```yaml
value:
  x-kubernetes-preserve-unknown-fields: true
  # no type: declaration
```

The absence of `type:` makes CEL treat `value` as `dyn`. The CRD then has a validation rule at the `spec` level:

```yaml
x-kubernetes-validations:
  - message: spec.forProvider.value is a required parameter
    rule: '... || has(self.forProvider.value)
      || (has(self.initProvider) && has(self.initProvider.value))'
```

Kubernetes rejects the CRD at install time because the CEL compiler cannot statically type-check `has()` on a `dyn`-typed field. No resources can be created — the provider fails to install entirely.

**Why the rule exists:** This is the standard Crossplane pattern for conditionally required fields. The intent is: when `managementPolicies` includes `Create` or `Update`, `value` must be provided (either in `forProvider` or `initProvider`). It's allowed to be absent only in observe-only mode. The same pattern is used correctly for `settingId`, `zoneId`, and `hostname` in the same files — those work because they have `type: string`.

**Why simply deleting the rule is insufficient:** The CRD installs, but Kubernetes no longer validates that `value` is present. A user who omits `value` gets a cryptic reconciliation error from the Cloudflare API instead of a clear admission rejection.

**The correct fix:** replace `has(self.forProvider.value)` with `"value" in self.forProvider`. The `in` operator checks for key presence on the **parent object**, which has `type: object` — something CEL can statically type-check. The `dyn` type of `value` itself is never referenced.

```yaml
# Before — fails CEL type-checking at CRD install
rule: '... || has(self.forProvider.value)
  || (has(self.initProvider) && has(self.initProvider.value))'

# After — works, preserves original validation intent
rule: '... || "value" in self.forProvider
  || (has(self.initProvider) && "value" in self.initProvider)'
```

**Affected files:**
- `package/crds/hostname.upjet-cloudflare.m.upbound.io_tlssettings.yaml`
- `package/crds/hostname.upjet-cloudflare.upbound.io_tlssettings.yaml`
- `package/crds/zone.upjet-cloudflare.m.upbound.io_settings.yaml`
- `package/crds/zone.upjet-cloudflare.upbound.io_settings.yaml`

---

## License Compliance

| Repo | License |
|------|---------|
| `wildbitca/provider-upjet-cloudflare` | Apache-2.0 |
| `crossplane-contrib/provider-upjet-cloudflare` | Apache-2.0 |
| `upbound/upjet` | Apache-2.0 |
| `crossplane/crossplane` | Apache-2.0 |
| `cloudflare/terraform-provider-cloudflare` | MPL-2.0 |

**Verdict: fully compliant.** Apache-2.0 permits forking, modifying, and redistributing in any form including OCI artifacts.

MPL-2.0 (Cloudflare Terraform provider) does not apply — it is used by Upjet as a schema generation tool at build time only; its code is not linked into the generated provider. MPL-2.0 does not reach generated output.

**Mandatory requirements (Apache-2.0):**
1. Retain the original `LICENSE` file unchanged.
2. Add a modification notice comment to the top of each of the 4 edited CRD files.
3. Preserve all existing copyright headers.

---

## Implementation Steps

### 1. Fork on GitHub

Go to `https://github.com/wildbitca/provider-upjet-cloudflare` → **Fork** → fork to `StanleyXie`.

### 2. Clone and create fix branch

```bash
git clone https://github.com/StanleyXie/provider-upjet-cloudflare
cd provider-upjet-cloudflare
git checkout -b fix/cel-validation-bug
```

### 3. Fix the 4 CRD files

In each of the 4 files listed above, replace the invalid rule with the corrected one:

```yaml
# Before
- message: spec.forProvider.value is a required parameter
  rule: '!(''*'' in self.managementPolicies || ''Create'' in self.managementPolicies
    || ''Update'' in self.managementPolicies) || has(self.forProvider.value)
    || (has(self.initProvider) && has(self.initProvider.value))'

# After
- message: spec.forProvider.value is a required parameter
  rule: '!(''*'' in self.managementPolicies || ''Create'' in self.managementPolicies
    || ''Update'' in self.managementPolicies) || "value" in self.forProvider
    || (has(self.initProvider) && "value" in self.initProvider)'
```

And add this modification notice at the top of each file:
```yaml
# Modified by StanleyXie — replaced invalid CEL has() with 'in' operator for dyn-typed value field.
# Original: https://github.com/wildbitca/provider-upjet-cloudflare
```

### 4. Update the publish workflow

The existing `.github/workflows/publish.yml` targets Upbound's registry. Update it to push to GHCR instead.

Key changes needed:
- Login step: use `docker/login-action` with `registry: ghcr.io`, `username: ${{ github.actor }}`, `password: ${{ secrets.GITHUB_TOKEN }}`
- Package destination: `ghcr.io/stanleyxie/provider-upjet-cloudflare:${{ github.ref_name }}`
- The crossplane/upbound `xpkg push` command should target `ghcr.io/stanleyxie/provider-upjet-cloudflare`

### 5. Enable GHCR write access

GitHub → fork repo → **Settings → Actions → General → Workflow permissions** → set to **Read and write permissions**.

### 6. Commit, tag, and push

```bash
git add package/crds/hostname.upjet-cloudflare.m.upbound.io_tlssettings.yaml \
        package/crds/hostname.upjet-cloudflare.upbound.io_tlssettings.yaml \
        package/crds/zone.upjet-cloudflare.m.upbound.io_settings.yaml \
        package/crds/zone.upjet-cloudflare.upbound.io_settings.yaml \
        .github/workflows/publish.yml
git commit -m "fix: replace has() with 'in' operator for dyn-typed value field in 4 CRDs"
git push origin fix/cel-validation-bug
git tag v0.1.0-patched
git push origin v0.1.0-patched
```

The tag push triggers the publish workflow. Monitor it in the **Actions** tab of the fork.

### 7. Enable in the platform repo

Once `ghcr.io/stanleyxie/provider-upjet-cloudflare:v0.1.0-patched` is confirmed published, uncomment the provider manifest:

**File:** `~/platform/crossplane-providers/provider-cloudflare.yaml`

Uncomment the block at the bottom:
```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-cloudflare
spec:
  package: ghcr.io/stanleyxie/provider-upjet-cloudflare:v0.1.0-patched
  packagePullPolicy: IfNotPresent
  revisionActivationPolicy: Automatic
  runtimeConfigRef:
    name: default
```

Then push to GitHub — ArgoCD picks it up within 3 minutes.

### 8. Verify installation

```bash
kubectl get provider provider-cloudflare -n crossplane-system
kubectl describe provider provider-cloudflare -n crossplane-system
```

Expected: `INSTALLED: True`, `HEALTHY: True`.

---

## Final Verdict — wildbitca fork is unfixable by manual patching

After attempting to patch the fork through v0.1.3-patched, three compounding defects were found:

1. **CEL validation rule** (4 CRDs) — `has()` on a `dyn`-typed field fails at install time. Neither `has()` nor `"value" in self.forProvider` works: `forProvider` is a struct, not a map. Only deletion of the rule is viable, which loses admission-time validation.

2. **Missing `Snippet` CRD** — The provider binary expects both `Snippet` and `Snippets` kinds under `cloudflare.upjet-cloudflare.upbound.io/v1alpha1`. The wildbitca package only includes `Snippets` (plural). The controller manager crashes at startup with `no matches for kind "Snippet"`.

3. **`kind` naming inconsistency** — The `Snippets` CRD has `spec.names.kind: Snippets` (plural) but the compiled Go type expects the singular form. Changing the CRD kind is impossible after creation (`spec.names.kind` is immutable). These mismatches require full Upjet code regeneration, not manual patching.

**Conclusion:** The wildbitca fork requires the full Upjet toolchain to regenerate correct CRDs from the Cloudflare Terraform provider schema. This is beyond the scope of a manual fork patch.

---

## Path Forward

Monitor `crossplane-contrib/provider-upjet-cloudflare` for an official release:
- `https://github.com/crossplane-contrib/provider-upjet-cloudflare/releases`

When released, update `platform/crossplane-providers/provider-cloudflare.yaml`:
```yaml
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-upjet-cloudflare:<version>
```
