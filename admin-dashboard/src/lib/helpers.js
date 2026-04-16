export function cleanLabel(name) {
  if (!name) return 'Unknown'
  return name.replace(/^[A-Za-z]+___/, '').replace(/_/g, ' ')
}

export function maskUrl(url) {
  if (!url) return '—'
  try {
    const u = new URL(url)
    return `${u.protocol}//${u.hostname.slice(0, 8)}…`
  } catch {
    return url.slice(0, 22) + '…'
  }
}

export function downloadFile(content, filename, type) {
  const a = Object.assign(document.createElement('a'), {
    href: URL.createObjectURL(new Blob([content], { type })),
    download: filename,
  })
  a.click()
  setTimeout(() => URL.revokeObjectURL(a.href), 10000)
}

export function formatDateTime(dateStr) {
  if (!dateStr) return '—'
  return new Date(dateStr).toLocaleString()
}

export function formatBytes(bytes) {
  if (!bytes) return '0 B'
  const units = ['B', 'KB', 'MB', 'GB']
  let i = 0
  while (bytes >= 1024 && i < units.length - 1) { bytes /= 1024; i++ }
  return `${bytes.toFixed(1)} ${units[i]}`
}

// ── GitHub Actions integration ─────────────────────────────────────────────

// GitHub slug validation: owner/repo names must be alphanumeric + limited punctuation.
// This prevents tainted sessionStorage values from being injected into API URLs (SSRF).
const _GH_SLUG_RE = /^[a-zA-Z0-9_.-]{1,100}$/
export function validateGitHubSlugs(owner, repo) {
  if (!_GH_SLUG_RE.test(owner)) throw new Error(`Invalid GitHub owner: "${owner}"`)
  if (!_GH_SLUG_RE.test(repo))  throw new Error(`Invalid GitHub repo: "${repo}"`)
}

// All GitHub config (including gh_token) is stored in sessionStorage so it
// is cleared when the tab closes — minimizes PAT exposure window.
export function getGitHubConfig() {
  return {
    ghToken: sessionStorage.getItem('gh_token') || '',
    ghOwner: sessionStorage.getItem('gh_owner') || '',
    ghRepo:  sessionStorage.getItem('gh_repo')  || '',
    ghBranch: sessionStorage.getItem('gh_branch') || 'main',
  }
}

export async function triggerGitHubWorkflow(workflow, inputs = {}) {
  const stamp = checkRateLimit(workflow, 30000)
  const { ghToken, ghOwner, ghRepo, ghBranch } = getGitHubConfig()
  if (!ghToken || !ghOwner || !ghRepo) throw new Error('GitHub not configured. Go to Settings → Integrations.')
  // Validate slugs before URL construction (SSRF prevention)
  validateGitHubSlugs(ghOwner, ghRepo)
  const res = await fetch(
    `https://api.github.com/repos/${ghOwner}/${ghRepo}/actions/workflows/${workflow}/dispatches`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${ghToken}`,
        Accept: 'application/vnd.github.v3+json',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ ref: ghBranch, inputs }),
    }
  )
  if (res.status !== 204) {
    const err = await res.json().catch(() => ({}))
    throw new Error(err.message || `GitHub API error (${res.status})`)
  }
  // Fix 2.5: Only stamp cooldown AFTER successful dispatch
  stamp()
  return true
}

export async function getGitHubWorkflowRuns(workflow) {
  const { ghToken, ghOwner, ghRepo } = getGitHubConfig()
  if (!ghToken || !ghOwner || !ghRepo) return null
  // Validate slugs before URL construction (SSRF prevention)
  try { validateGitHubSlugs(ghOwner, ghRepo) } catch { return null }
  const res = await fetch(
    `https://api.github.com/repos/${ghOwner}/${ghRepo}/actions/workflows/${workflow}/runs?per_page=10`,
    { headers: { Authorization: `Bearer ${ghToken}`, Accept: 'application/vnd.github.v3+json' } }
  )
  if (!res.ok) return null
  return res.json()
}

// ── Supabase Storage helpers ───────────────────────────────────────────────

export async function uploadToStorage(supabase, bucket, path, file, onProgress) {
  // Supabase JS v2 doesn't have native progress; use XHR workaround for large files
  const { data, error } = await supabase.storage.from(bucket).upload(path, file, {
    cacheControl: '3600',
    upsert: true,
    contentType: file.type || 'application/octet-stream',
  })
  if (error) throw new Error(error.message)
  const { data: { publicUrl } } = supabase.storage.from(bucket).getPublicUrl(data.path)
  return publicUrl
}

export async function ensureBucket(supabase, bucket) {
  const { error } = await supabase.storage.createBucket(bucket, { public: true })
  // Ignore "already exists" error
  if (error && !(typeof error?.message === 'string' && error.message.includes('already'))) {
    console.warn('Bucket:', error?.message ?? error)
  }
}

// ── Rate limiting ─────────────────────────────────────────────────────────

export function checkRateLimit(key, cooldownMs = 30000) {
  try {
    const last = parseInt(localStorage.getItem(`rate_${key}`) || '0')
    const now = Date.now()
    if (now - last < cooldownMs) {
      const remaining = Math.ceil((cooldownMs - (now - last)) / 1000)
      throw new Error(`Please wait ${remaining}s before triggering "${key}" again.`)
    }
    // Fix 2.5: Timestamp set HERE (before action), but caller (triggerGitHubWorkflow)
    // is the one that calls checkRateLimit. If the workflow dispatch fails, the
    // timestamp is already set. To fix: return a callback to stamp on success.
  } catch (err) {
    if (err.message.includes('Please wait')) throw err
  }
  // Return a stamp function — caller invokes AFTER success
  return () => { localStorage.setItem(`rate_${key}`, String(Date.now())) }
}

// ── SHA-256 checksum ──────────────────────────────────────────────────────

export async function computeSHA256(file) {
  const buffer = await file.arrayBuffer()
  const hashBuffer = await crypto.subtle.digest('SHA-256', buffer)
  const hashArray = Array.from(new Uint8Array(hashBuffer))
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('')
}

// ── Audit logging ─────────────────────────────────────────────────────────

export async function logAudit(supabase, action, entityType, entityId, details = {}) {
  try {
    const { data: { user } } = await supabase.auth.getUser()
    await supabase.from('audit_log').insert({
      user_id: user?.id,
      action,
      entity_type: entityType,
      entity_id: entityId,
      details,
    })
  } catch (err) {
    console.warn('Audit log failed:', err.message)
  }
}

// ── Deep equality ────────────────────────────────────────────────────────

/** Deep equality comparison for JSON-serializable objects.
 *  Used for config sync detection (avoids JSON.stringify key-order sensitivity). */
export function deepEqual(a, b) {
  if (a === b) return true
  if (a == null || b == null) return false
  if (typeof a !== typeof b) return false
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false
    return a.every((v, i) => deepEqual(v, b[i]))
  }
  if (typeof a === 'object') {
    const ka = Object.keys(a), kb = Object.keys(b)
    if (ka.length !== kb.length) return false
    return ka.every(k => Object.prototype.hasOwnProperty.call(b, k) && deepEqual(a[k], b[k]))
  }
  return false
}
