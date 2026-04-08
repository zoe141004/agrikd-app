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

// All GitHub config (including gh_token) is stored in localStorage so it
// persists across tab closes and browser restarts.
export function getGitHubConfig() {
  return {
    ghToken: localStorage.getItem('gh_token') || '',
    ghOwner: localStorage.getItem('gh_owner') || '',
    ghRepo:  localStorage.getItem('gh_repo')  || '',
    ghBranch: localStorage.getItem('gh_branch') || 'main',
  }
}

export async function triggerGitHubWorkflow(workflow, inputs = {}) {
  checkRateLimit(workflow, 30000)
  const { ghToken, ghOwner, ghRepo, ghBranch } = getGitHubConfig()
  if (!ghToken || !ghOwner || !ghRepo) throw new Error('GitHub not configured. Go to Settings → Integrations.')
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
  return true
}

export async function getGitHubWorkflowRuns(workflow) {
  const { ghToken, ghOwner, ghRepo } = getGitHubConfig()
  if (!ghToken || !ghOwner || !ghRepo) return null
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
  if (error && !error.message?.includes('already')) console.warn('Bucket:', error.message)
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
    localStorage.setItem(`rate_${key}`, String(now))
  } catch (err) {
    if (err.message.includes('Please wait')) throw err
  }
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
