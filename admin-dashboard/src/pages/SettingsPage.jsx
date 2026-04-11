import { useState, useEffect } from 'react'
import { supabase } from '../lib/supabase'
import { useData } from '../lib/DataContext'
import { maskUrl, triggerGitHubWorkflow, getGitHubConfig, validateGitHubSlugs, formatDateTime, logAudit } from '../lib/helpers'
import ConfirmDialog from '../components/ConfirmDialog'

const STABS = ['General', 'Integrations', 'Admin', 'CI/CD', 'Deployment', 'Audit Log']

export default function SettingsPage() {
  const { ghConnectionStatus, setGhConnectionStatus, triggerRefresh, refreshKey, dvcDatasets } = useData()
  const [stab, setStab] = useState('General')
  const [models, setModels] = useState([])
  const [envInfo, setEnvInfo] = useState({})
  const [newAdminEmail, setNewAdminEmail] = useState('')
  const [addingAdmin, setAddingAdmin] = useState(false)
  const [adminMsg, setAdminMsg] = useState('')
  const [ghSaved, setGhSaved] = useState(false)
  const [confirmAction, setConfirmAction] = useState(null)

  // GitHub config (all fields stored in sessionStorage — cleared on tab close)
  const [ghForm, setGhForm] = useState({ ghOwner: '', ghRepo: '', ghToken: '', ghBranch: 'main' })
  const [ghTestMsg, setGhTestMsg] = useState(null)

  // CI/CD trigger
  const [ciMsg, setCiMsg] = useState(null)
  const [ciRunning, setCiRunning] = useState('')
  const [auditLogs, setAuditLogs] = useState([])
  const [auditLoading, setAuditLoading] = useState(false)
  const [auditError, setAuditError] = useState(null)
  const [auditPage, setAuditPage] = useState(0)
  const [auditHasMore, setAuditHasMore] = useState(true)
  const AUDIT_PAGE_SIZE = 50
  const [ghTesting, setGhTesting] = useState(false)

  useEffect(() => {
    const loadSystemInfo = async () => {
      const [modelsRes, predsRes, dvcRes, usersRes] = await Promise.allSettled([
        supabase.from('model_registry').select('leaf_type, version, model_url, status'),
        supabase.from('predictions').select('*', { count: 'exact', head: true }),
        supabase.from('dvc_operations').select('*', { count: 'exact', head: true }),
        supabase.from('profiles').select('*', { count: 'exact', head: true }),
      ])
      setModels(modelsRes.status === 'fulfilled' ? modelsRes.value?.data || [] : [])
      const predCount = predsRes.status === 'fulfilled' ? predsRes.value?.count || 0 : 0
      const dvcCount = dvcRes.status === 'fulfilled' ? dvcRes.value?.count || 0 : 0
      const userCount = usersRes.status === 'fulfilled' ? usersRes.value?.count || 0 : 0
      setEnvInfo({
        supabaseUrl: import.meta.env.VITE_SUPABASE_URL || '',
        env: import.meta.env.MODE || 'production',
        predCount,
        dvcCount,
        userCount,
        modelCount: modelsRes.status === 'fulfilled' ? (modelsRes.value?.data || []).length : 0,
      })
    }
    loadSystemInfo()
    const cfg = getGitHubConfig()
    setGhForm({ ghOwner: cfg.ghOwner, ghRepo: cfg.ghRepo, ghToken: cfg.ghToken, ghBranch: cfg.ghBranch })
  }, [refreshKey])

  useEffect(() => {
    if (stab !== 'Audit Log') return
    setAuditPage(0)
    const controller = new AbortController()
    loadAuditLogs(controller.signal)
    return () => controller.abort()
  }, [stab])

  const saveGitHub = () => {
    const owner = (ghForm.ghOwner || '').trim()
    const repo = (ghForm.ghRepo || '').trim()
    const token = (ghForm.ghToken || '').trim()
    if (!owner) { setGhTestMsg({ type: 'error', text: 'Owner is required.' }); return }
    if (!repo) { setGhTestMsg({ type: 'error', text: 'Repository name is required.' }); return }
    if (!token) { setGhTestMsg({ type: 'error', text: 'Personal Access Token is required.' }); return }
    sessionStorage.setItem('gh_owner', owner)
    sessionStorage.setItem('gh_repo', repo)
    sessionStorage.setItem('gh_token', token)
    sessionStorage.setItem('gh_branch', (ghForm.ghBranch || 'main').trim())
    setGhSaved(true)
    setTimeout(() => setGhSaved(false), 2000)
  }

  const testGitHub = async () => {
    // Validate form fields first (not sessionStorage) so user gets immediate feedback
    const owner = (ghForm.ghOwner || '').trim()
    const repo = (ghForm.ghRepo || '').trim()
    const token = (ghForm.ghToken || '').trim()
    if (!owner || !repo || !token) {
      setGhTestMsg({ type: 'error', text: 'Complete and save GitHub config first (Owner, Repo, Token required).' })
      setGhConnectionStatus('error')
      return
    }
    setGhTesting(true); setGhTestMsg(null)
    try {
      validateGitHubSlugs(owner, repo)
      const ghController = new AbortController()
      const timeoutId = setTimeout(() => ghController.abort(), 10000)
      const res = await fetch(`https://api.github.com/repos/${owner}/${repo}`, { headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github.v3+json' }, signal: ghController.signal })
      clearTimeout(timeoutId)
      const data = await res.json()
      if (res.ok) {
        setGhTestMsg({ type: 'success', text: `✓ Connected to ${data.full_name} (${data.private ? 'private' : 'public'}). ${data.open_issues_count} open issues.` })
        setGhConnectionStatus('connected')
      } else {
        setGhTestMsg({ type: 'error', text: `Error: ${data.message}` })
        setGhConnectionStatus('error')
      }
    } catch (err) {
      setGhTestMsg({ type: 'error', text: err.name === 'AbortError' ? 'Connection timed out (10s).' : err.message })
      setGhConnectionStatus('error')
    } finally {
      setGhTesting(false)
    }
  }

  const triggerWorkflow = (workflow, label) => {
    setConfirmAction({
      title: `Trigger ${label}`,
      message: `Dispatch "${label}" (${workflow})? This will run the workflow on GitHub Actions.`,
      danger: false,
      confirmLabel: 'Trigger',
      onConfirm: async () => {
        setConfirmAction(null)
        setCiRunning(workflow); setCiMsg(null)
        try {
          await triggerGitHubWorkflow(workflow)
          setCiMsg({ type: 'success', text: `"${label}" workflow dispatched. Check GitHub Actions for progress.` })
          logAudit(supabase, 'workflow_triggered', 'workflow', workflow, { label })
        } catch (err) {
          setCiMsg({ type: 'error', text: err.message })
        } finally {
          setCiRunning('')
        }
      },
    })
  }

  const inviteAdmin = async () => {
    if (!newAdminEmail) return
    setAddingAdmin(true); setAdminMsg('')
    const { data: profile, error: lookupErr } = await supabase.from('profiles').select('id, email, role').eq('email', newAdminEmail).maybeSingle()
    if (lookupErr) { setAdminMsg('Error: ' + lookupErr.message); setAddingAdmin(false); return }
    if (!profile) { setAdminMsg('Error: No user found with that email. They must sign up first.'); setAddingAdmin(false); return }
    if (profile.role === 'admin') { setAdminMsg('This user is already an admin.'); setAddingAdmin(false); return }
    const { error } = await supabase.from('profiles').update({ role: 'admin' }).eq('id', profile.id)
    setAddingAdmin(false)
    if (error) setAdminMsg('Error: ' + error.message)
    else {
      setAdminMsg('Admin role granted to ' + newAdminEmail + '.')
      setNewAdminEmail('')
      logAudit(supabase, 'admin_granted', 'user', profile.id, { email: newAdminEmail })
      triggerRefresh()
    }
  }

  const { ghToken, ghOwner, ghRepo } = getGitHubConfig()
  const ghConfigured = !!(ghToken && ghOwner && ghRepo)

  return (
    <>
      <div className="page-header">
        <h1 className="page-title">Settings</h1>
        <p className="page-subtitle">App configuration, integrations, admin access, and CI/CD pipelines</p>
      </div>

      <div style={{ display: 'flex', gap: 0, marginBottom: 20, borderBottom: '1px solid rgba(0,0,0,0.08)' }}>
        {STABS.map(t => (
          <button key={t} onClick={() => setStab(t)} style={{ padding: '10px 16px', border: 'none', background: 'none', cursor: 'pointer', fontSize: 13, fontWeight: 600, color: stab === t ? '#16a34a' : '#64748b', borderBottom: `2px solid ${stab === t ? '#16a34a' : 'transparent'}`, fontFamily: 'inherit' }}>
            {t}
          </button>
        ))}
      </div>

      {/* ── General ── */}
      {stab === 'General' && (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
          <div className="card">
            <div className="card-header"><div><div className="card-label">App</div><div className="card-title">Application Info</div></div></div>
            {[
              ['Name', 'AgriKD Admin Console'],
              ['Description', 'Precision Agronomy MLOps Dashboard'],
              ['Version', '1.0.0'],
              ['Platform', 'Vercel + Supabase'],
              ['Architecture', 'Static SPA → Supabase REST'],
            ].map(([k, v]) => (
              <div key={k} style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0', borderBottom: '1px solid rgba(0,0,0,0.06)', fontSize: 13 }}>
                <span style={{ color: '#64748b' }}>{k}</span>
                <span style={{ color: '#121c28', fontWeight: 500 }}>{v}</span>
              </div>
            ))}
          </div>

          <div className="card">
            <div className="card-header"><div><div className="card-label">Runtime</div><div className="card-title">Environment & Stats</div></div></div>
            {[
              ['Mode', envInfo.env],
              ['Supabase URL', maskUrl(envInfo.supabaseUrl)],
              ['Auth Provider', 'Supabase Auth (email/pw)'],
              ['File Storage', 'Supabase Storage (models, datasets)'],
              ['Total Predictions', (envInfo.predCount ?? 0).toLocaleString()],
              ['Registered Models', (envInfo.modelCount ?? 0).toLocaleString()],
              ['DVC Operations', (envInfo.dvcCount ?? 0).toLocaleString()],
              ['Registered Users', (envInfo.userCount ?? 0).toLocaleString()],
            ].map(([k, v]) => (
              <div key={k} style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0', borderBottom: '1px solid rgba(0,0,0,0.06)', fontSize: 13 }}>
                <span style={{ color: '#64748b' }}>{k}</span>
                <span style={{ color: '#121c28', fontWeight: 500, fontFamily: k.includes('URL') ? 'monospace' : 'inherit', fontSize: k.includes('URL') ? 12 : 13 }}>{v || '—'}</span>
              </div>
            ))}
          </div>

          <div className="card" style={{ gridColumn: '1/-1' }}>
            <div className="card-header"><div><div className="card-label">OTA</div><div className="card-title">Model OTA Status</div></div></div>
            <table>
              <thead><tr><th>Leaf Type</th><th>Version</th><th>Model URL</th><th>Status</th><th>OTA Live</th></tr></thead>
              <tbody>
                {[...models].sort((a, b) => a.leaf_type.localeCompare(b.leaf_type) || b.version.localeCompare(a.version, undefined, { numeric: true })).map(m => (
                  <tr key={`${m.leaf_type}-${m.version}`}>
                    <td><strong style={{ color: '#121c28' }}>{m.leaf_type}</strong></td>
                    <td><span className="badge badge-primary">v{m.version}</span></td>
                    <td className="font-mono" style={{ color: '#94a3b8', maxWidth: 220, overflow: 'hidden', textOverflow: 'ellipsis' }}>{m.model_url ? maskUrl(m.model_url) : '—'}</td>
                    <td><span className={`badge ${m.status === 'active' ? 'badge-green' : m.status === 'backup' ? 'badge-gray' : 'badge-yellow'}`}>{(m.status || 'staging').charAt(0).toUpperCase() + (m.status || 'staging').slice(1)}</span></td>
                    <td><span className={`badge ${m.model_url && m.status === 'active' ? 'badge-green' : 'badge-red'}`}>{m.model_url && m.status === 'active' ? '✓ Serving' : '✗ Not live'}</span></td>
                  </tr>
                ))}
                {models.length === 0 && <tr><td colSpan={5} style={{ textAlign: 'center', color: '#94a3b8', padding: 24 }}>No models. Upload via Model Registry.</td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* ── Integrations ── */}
      {stab === 'Integrations' && (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
          <div className="card">
            <div className="card-header">
              <div>
                <div className="card-label" style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  GitHub
                  {ghConnectionStatus === 'connected'
                    ? <span className="badge badge-green">Connected</span>
                    : ghConnectionStatus === 'error'
                      ? <span className="badge badge-red">Connection Failed</span>
                      : ghConfigured
                        ? <span className="badge badge-yellow">Not Tested</span>
                        : <span className="badge badge-red">Not configured</span>}
                </div>
                <div className="card-title">GitHub Actions Integration</div>
              </div>
            </div>
            <div className="alert alert-info" style={{ marginBottom: 14 }}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/></svg>
              <div>Token stored in <code>sessionStorage</code> (cleared when tab closes). Required for DVC sync, model validation, and CI/CD triggers.</div>
            </div>
            <div className="form-group">
              <label className="form-label">Repository Owner</label>
              <input className="form-input" value={ghForm.ghOwner} onChange={e => setGhForm(f => ({ ...f, ghOwner: e.target.value }))} placeholder="your-username or org" />
            </div>
            <div className="form-group">
              <label className="form-label">Repository Name</label>
              <input className="form-input" value={ghForm.ghRepo} onChange={e => setGhForm(f => ({ ...f, ghRepo: e.target.value }))} placeholder="my-agrikd-repo" />
            </div>
            <div className="form-group">
              <label className="form-label">Default Branch</label>
              <input className="form-input" value={ghForm.ghBranch} onChange={e => setGhForm(f => ({ ...f, ghBranch: e.target.value }))} placeholder="main" />
            </div>
            <div className="form-group">
              <label className="form-label">Personal Access Token (PAT)</label>
              <input className="form-input" type="password" value={ghForm.ghToken} onChange={e => setGhForm(f => ({ ...f, ghToken: e.target.value }))} placeholder="ghp_xxxxxxxxxxxx" />
              <div style={{ fontSize: 11, color: '#94a3b8', marginTop: 3 }}>Classic PAT: <code>repo</code> + <code>workflow</code>. Fine-grained: <code>actions</code>, <code>contents</code>, <code>metadata</code>, <code>pull_requests</code>. Never committed to code.</div>
            </div>
            <div style={{ display: 'flex', gap: 8 }}>
              <button className="btn btn-primary" onClick={saveGitHub}>{ghSaved ? '✓ Saved' : 'Save Config'}</button>
              <button className="btn" onClick={testGitHub} disabled={ghTesting}>{ghTesting ? 'Testing…' : 'Test Connection'}</button>
            </div>
            {ghTestMsg && (
              <div className={`alert ${ghTestMsg.type === 'error' ? 'alert-error' : 'alert-success'}`} style={{ marginTop: 12 }}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                {ghTestMsg.text}
              </div>
            )}
          </div>
        </div>
      )}

      {/* ── Admin ── */}
      {stab === 'Admin' && (
        <div style={{ maxWidth: 600 }}>
          <div className="card">
            <div className="card-header"><div><div className="card-label">Access Control</div><div className="card-title">Grant Admin Role</div></div></div>
            <p style={{ fontSize: 13, color: '#64748b', marginBottom: 14 }}>
              Sets <code>role = 'admin'</code> in the <code>profiles</code> table. User must already have a Supabase Auth account. Applies on next login.
            </p>
            <div style={{ display: 'flex', gap: 10, marginBottom: 10 }}>
              <input className="form-input" type="email" placeholder="user@example.com" value={newAdminEmail} onChange={e => setNewAdminEmail(e.target.value)} style={{ flex: 1 }} />
              <button className="btn btn-primary" onClick={() => {
                if (!newAdminEmail) return
                setConfirmAction({ title: 'Grant Admin Access', message: `Grant admin privileges to ${newAdminEmail}? They will have full access to this dashboard.`, danger: false, confirmLabel: 'Grant Admin', onConfirm: () => { setConfirmAction(null); inviteAdmin() } })
              }} disabled={addingAdmin || !newAdminEmail}>{addingAdmin ? 'Processing...' : 'Grant Admin'}</button>
            </div>
            {adminMsg && (
              <div className={`alert ${adminMsg.startsWith('Error') ? 'alert-error' : 'alert-success'}`}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                {adminMsg}
              </div>
            )}
          </div>

          <div className="card">
            <div className="card-header"><div><div className="card-label">Security</div><div className="card-title">Supabase RLS Reminder</div></div></div>
            {[
              { ok: true, item: 'predictions table: RLS enabled (users see own rows)' },
              { ok: true, item: 'model_registry table: RLS enabled (public read, admin write)' },
              { ok: !!(envInfo.userCount > 0), item: 'profiles table: RLS enabled (users see own profile, admin sees all)' },
              { ok: !import.meta.env.VITE_SUPABASE_SERVICE_ROLE_KEY, item: 'Service role key NOT used in frontend (only anon key)' },
            ].map((c, i) => (
              <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 0', borderBottom: '1px solid rgba(0,0,0,0.06)', fontSize: 13 }}>
                <span className={`status-dot ${c.ok ? 'green' : 'yellow'}`} />
                <span style={{ color: c.ok ? '#14532d' : '#713f12' }}>{c.item}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* ── CI/CD ── */}
      {stab === 'CI/CD' && (
        <div>
          {!ghConfigured && (
            <div className="alert alert-warn" style={{ marginBottom: 16 }}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/></svg>
              <div>GitHub not configured. <strong>Go to Integrations tab</strong> to add your GitHub token before using CI/CD.</div>
            </div>
          )}

          {ciMsg && (
            <div className={`alert ${ciMsg.type === 'error' ? 'alert-error' : 'alert-success'}`} style={{ marginBottom: 16 }}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><path d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
              <div>{ciMsg.text}</div>
            </div>
          )}

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 16 }}>
            {[
              { workflow: 'dvc-push.yml', label: 'DVC Push', desc: 'Sync prediction data to DVC remote (GCS)', color: '#16a34a' },
              { workflow: 'dvc-pull.yml', label: 'DVC Pull', desc: 'Pull latest tracked data from DVC remote', color: '#0284c7' },
              { workflow: 'deploy.yml', label: 'Redeploy App', desc: 'Trigger Vercel production deployment via GitHub push', color: '#ca8a04' },
              { workflow: 'export-data.yml', label: 'Export to DVC', desc: 'Export prediction DB snapshot and push to DVC', color: '#065f46' },
            ].map(w => (
              <div key={w.workflow} style={{ background: '#fff', borderRadius: 12, padding: 16, boxShadow: '0 2px 8px rgba(18,28,40,0.06)', borderTop: `3px solid ${w.color}` }}>
                <div style={{ fontFamily: 'Manrope, sans-serif', fontWeight: 700, fontSize: 14, color: '#121c28', marginBottom: 4 }}>{w.label}</div>
                <div style={{ fontSize: 12, color: '#64748b', marginBottom: 12, lineHeight: 1.5 }}>{w.desc}</div>
                <div style={{ fontSize: 11, color: '#94a3b8', marginBottom: 10, fontFamily: 'monospace' }}>{w.workflow}</div>
                <button className="btn btn-sm btn-primary" onClick={() => triggerWorkflow(w.workflow, w.label)} disabled={!ghConfigured || !!ciRunning}>
                  {ciRunning === w.workflow ? <><div className="spinner" style={{ width: 12, height: 12, borderWidth: 2 }} /> Running…</> : 'Trigger'}
                </button>
              </div>
            ))}
          </div>

          <div className="alert alert-info" style={{ marginTop: 16 }}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/></svg>
            <div><strong>Validate Model</strong> and <strong>Training</strong> workflows require leaf_type input and are triggered from the <strong>Models</strong> page instead.</div>
          </div>

          <div className="card" style={{ marginTop: 20 }}>
            <div className="card-header"><div><div className="card-label">Reference</div><div className="card-title">Required GitHub Actions Workflow Files</div></div></div>
            <p style={{ fontSize: 13, color: '#64748b', marginBottom: 14 }}>Place these YAML files in <code>.github/workflows/</code> in your repository. Each must accept <code>workflow_dispatch</code> trigger.</p>
            <div style={{ background: '#0f172a', borderRadius: 8, padding: 16, fontFamily: 'monospace', fontSize: 12, color: '#94a3b8', lineHeight: 1.8 }}>
              <div style={{ color: '#4ade80' }}># Example: validate-model.yml</div>
              <div>name: Validate Model</div>
              <div>on:</div>
              <div>{'  '}workflow_dispatch:</div>
              <div>{'    '}inputs:</div>
              <div>{'      '}leaf_type:</div>
              <div>{'        '}description: 'Leaf type to validate'</div>
              <div>{'        '}required: true</div>
              <div>jobs:</div>
              <div>{'  '}validate:</div>
              <div>{'    '}runs-on: ubuntu-latest</div>
              <div>{'    '}steps:</div>
              <div>{'      '}- uses: actions/checkout@v5</div>
              <div>{'      '}- run: pip install -r requirements.txt</div>
              <div>{'      '}- run: python scripts/validate.py --leaf_type {'${{ inputs.leaf_type }}'}</div>
            </div>
          </div>
        </div>
      )}

      {/* ── Deployment ── */}
      {stab === 'Deployment' && (
        <div style={{ maxWidth: 680 }}>
          <div className="card">
            <div className="card-header"><div><div className="card-label">Vercel</div><div className="card-title">Deployment Checklist</div></div></div>
            {[
              { ok: true, item: 'Framework: Vite (React)' },
              { ok: true, item: 'Build command: vite build' },
              { ok: true, item: 'Output directory: dist' },
              { ok: !!import.meta.env.VITE_SUPABASE_URL, item: 'VITE_SUPABASE_URL — set in Vercel Project Settings → Environment Variables' },
              { ok: !!import.meta.env.VITE_SUPABASE_ANON_KEY, item: 'VITE_SUPABASE_ANON_KEY — set in Vercel Project Settings → Environment Variables' },
              { ok: true, item: 'vercel.json: SPA rewrite rule added (handles all routes → index.html)' },
              { ok: true, item: 'No server-side code — 100% static SPA' },
              { ok: true, item: 'All API calls client-side via Supabase JS SDK' },
              { ok: !!(envInfo.predCount > 0 || envInfo.modelCount > 0), item: 'Supabase Anon key has minimum required RLS (verify in Supabase dashboard)' },
              { ok: models.length > 0, item: 'Supabase Storage buckets "models" and "datasets" created as Public' },
              { ok: ghConfigured, item: 'GitHub workflow files committed to repo for DVC/validation CI/CD' },
            ].map((c, i) => (
              <div key={i} style={{ display: 'flex', alignItems: 'flex-start', gap: 10, padding: '8px 0', borderBottom: '1px solid rgba(0,0,0,0.06)', fontSize: 13 }}>
                <span className={`status-dot ${c.ok ? 'green' : 'yellow'}`} style={{ marginTop: 3, flexShrink: 0 }} />
                <span style={{ color: c.ok ? '#14532d' : '#713f12' }}>{c.item}</span>
              </div>
            ))}
          </div>

          <div className="card">
            <div className="card-header"><div><div className="card-label">DVC</div><div className="card-title">Data Version Control Config</div></div></div>
            {[
              ...dvcDatasets.map(ds => [`${ds.name} DVC file`, ds.file || `data_${ds.name}.dvc`]),
              ...(dvcDatasets.length === 0 ? [['Tracked datasets', 'None detected — upload via Data & DVC page']] : []),
              ['Remote type', 'Google Cloud Storage (gs://agrikd-dvc-data)'],
              ['DVC config path', '.dvc/config'],
              ['CI trigger', 'Settings → CI/CD → DVC Push/Pull buttons'],
            ].map(([k, v]) => (
              <div key={k} style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0', borderBottom: '1px solid rgba(0,0,0,0.06)', fontSize: 13 }}>
                <span style={{ color: '#64748b' }}>{k}</span>
                <span className="font-mono" style={{ color: '#121c28' }}>{v}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* ── Audit Log Tab ── */}
      {stab === 'Audit Log' && (
        <div className="card">
          <div className="card-header">
            <div><div className="card-label">Activity</div><div className="card-title">Admin Audit Log</div></div>
            <button className="btn btn-sm btn-primary" onClick={() => loadAuditLogs()} disabled={auditLoading}>
              {auditLoading ? 'Loading…' : 'Refresh'}
            </button>
          </div>
          {auditError && <div className="alert alert-error" style={{ margin: '0 16px 12px' }}>{auditError}</div>}
          {auditLogs.length > 0 ? (
            <>
            <div className="table-wrapper">
              <table>
                <thead><tr><th>Action</th><th>Entity</th><th>Entity ID</th><th>User</th><th>Date</th><th>Details</th></tr></thead>
                <tbody>
                  {auditLogs.map(log => (
                    <tr key={log.id}>
                      <td><span className="badge badge-primary">{log.action}</span></td>
                      <td>{log.entity_type || '—'}</td>
                      <td className="font-mono" style={{ color: '#94a3b8', fontSize: 11 }}>{log.entity_id ? String(log.entity_id).slice(0, 12) + '…' : '—'}</td>
                      <td className="font-mono" style={{ color: '#94a3b8', fontSize: 11 }}>{log.user_id ? String(log.user_id).slice(0, 12) + '…' : '—'}</td>
                      <td style={{ fontSize: 12, color: '#64748b' }}>{formatDateTime(log.created_at)}</td>
                      <td style={{ fontSize: 11, color: '#94a3b8', maxWidth: 200, overflow: 'hidden', textOverflow: 'ellipsis' }}>{log.details ? JSON.stringify(log.details) : '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 12 }}>
              <button className="btn btn-sm" disabled={auditPage === 0 || auditLoading} onClick={() => loadAuditLogs(null, auditPage - 1)}>← Previous</button>
              <span style={{ color: '#94a3b8', fontSize: 13 }}>Page {auditPage + 1}</span>
              <button className="btn btn-sm" disabled={!auditHasMore || auditLoading} onClick={() => loadAuditLogs(null, auditPage + 1)}>Next →</button>
            </div>
            </>
          ) : (
            <div className="empty-state"><p>No audit log entries yet. Actions like model uploads, edits, and deletions will appear here.</p></div>
          )}
        </div>
      )}

      <ConfirmDialog open={!!confirmAction} {...(confirmAction || {})} onCancel={() => setConfirmAction(null)} />
    </>
  )

  async function loadAuditLogs(signal, page = 0) {
    const safePage = Math.max(0, page || 0)
    setAuditLoading(true)
    setAuditError(null)
    try {
      const from = safePage * AUDIT_PAGE_SIZE
      const to = from + AUDIT_PAGE_SIZE - 1
      const { data, error: err } = await supabase
        .from('audit_log').select('*')
        .order('created_at', { ascending: false }).range(from, to)
      if (signal?.aborted) return
      if (err) throw err
      setAuditLogs(data || [])
      setAuditHasMore((data || []).length >= AUDIT_PAGE_SIZE)
      setAuditPage(safePage)
    } catch (err) {
      if (err.name !== 'AbortError' && !signal?.aborted) {
        setAuditError(err.message || 'Failed to load audit logs')
        setAuditHasMore(false)
      }
    }
    if (!signal?.aborted) setAuditLoading(false)
  }
}
